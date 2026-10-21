"""The vanilla stages a diff can affect, for `check_vanilla.py --changed [REV]`.

A changed file selects a stage when:

- it is a global input (build, toolchain, the runner, the pin): every stage;
- it is one of the stage's scripts, or a file one requires: the stage;
- it is an oracle source in the closure of one of the stage's oracle classes, or a repo
  file one of them declares (`INPUTS`), or a fact file a `same` step compares;
- its changed lines lie in an Elixir function the stage's scripts reach in the call graph
  (`call_graph.exs`: calls, modules named as values, process modules, behaviours), or in
  a module that function's module needs at compile time (`mix xref`);
- it is a `priv/` file a module reads (by name), which changes that whole module;
- it is native code reaching a NIF through the crate's module graph: the NIF's
  `Valimc.Native` function changes;
- the stage's tuple in `vanilla_stages.py` changed.

Anything else (docs, tests, benchmarks, other tools) selects nothing. Each selection
carries the first reason found.
"""
import collections, fnmatch, hashlib, json, pathlib, re, subprocess

GLOBAL = ['mix.exs', 'mix.lock', 'config/*', '.tool-versions', 'priv/version.json', 'native/Cargo.toml',
          'native/Cargo.lock', 'native/*/Cargo.toml', 'native/*/build.rs', 'scripts/check_vanilla.py',
          'scripts/oracle_cache.py', 'scripts/java_tool.py', 'scripts/java_runtime.py', 'scripts/pinned.py',
          'scripts/run_checks.exs', 'research/mojang-version.json']
# Stages that start the application also depend on its startup.
APP = ['lib/valimc/application.ex']
# The TCP stage drives a whole server: these modules and everything they reach.
TCP_SEEDS = ['Valimc.Application', 'Valimc.Listener', 'Valimc.Connection']
NATIVE_CORE = 'native/valimc_core/src'
NATIVE_NIF = 'native/valimc_nif/src/lib.rs'


def git(root, *args):
    return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True, check=True).stdout


def base_revision(root):
    try:
        return git(root, 'merge-base', 'HEAD', 'origin/main').strip()
    except subprocess.CalledProcessError:
        return 'HEAD'


def changes(root, rev):
    """{path: set of changed new-side lines, or None for the whole file}, committed and uncommitted
    changes since `rev` plus untracked files."""
    out = {}
    for line in git(root, 'diff', '--name-status', '--no-renames', rev).splitlines():
        status, path = line.split('\t', 1)
        out[path] = None if status[0] in 'AD' else set()
    for path in git(root, 'ls-files', '--others', '--exclude-standard').splitlines():
        out[path] = None
    current = None
    for line in git(root, 'diff', '-U0', '--no-renames', rev).splitlines():
        if line.startswith('+++ '):
            current = line[6:] if line.startswith('+++ b/') else None
        elif line.startswith('@@') and current and out.get(current) is not None:
            match = re.match(r'@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', line)
            start, count = int(match[1]), int(match[2] if match[2] is not None else 1)
            # A pure deletion touches the lines around where it was.
            out[current].update(range(start, start + count) if count else (start, start + 1))
    return out


# -- Elixir ------------------------------------------------------------------------------

class Graph:
    """Reachability over function clauses, following message and argument tags.

    A function entered with a tag (its first argument's atom or tuple tag) runs only the
    clauses whose first parameter can match it; a clause that takes anything passes the
    tag on where it hands that parameter to a call or a send. A send reaches the matching
    callback clauses of its named server, or of every process module. A function that
    sends one of its parameters (directly or through another such function) sends, at
    each call site, whatever that call passes there; reached without a call site, it may
    send anything. A module named as a value reaches all its functions but its message
    callbacks (and private functions); a behaviour reaches the public functions of the
    modules that declare it.
    """
    CALLBACKS = {'call': 'handle_call', 'cast': 'handle_cast', 'info': 'handle_info'}

    def __init__(self, data, compile_edges):
        self.modules = data['modules']
        self.scripts = data['scripts']
        self.functions = {m: [f'{m}.{f}' for f in d['functions']] for m, d in self.modules.items()}
        self.clauses = {f'{m}.{f}': clauses for m, d in self.modules.items() for f, clauses in d['functions'].items()}
        self.implementers = collections.defaultdict(set)
        for module, info in self.modules.items():
            for behaviour in info['behaviours']:
                self.implementers[behaviour].add(module)
        self.receivers = {kind: [f'{m}.{cb}' for m, d in self.modules.items() if cb in d['functions']]
                          for kind, cb in self.CALLBACKS.items()}
        self.by_file = collections.defaultdict(list)
        for module, info in self.modules.items():
            self.by_file[info['file']].append(module)
        self.compile_edges = compile_edges
        self.passes = self.pass_through()

    @staticmethod
    def params(clause):
        return {shape: k for k, shape in enumerate(clause['params']) if shape.startswith('v:')}

    def pass_through(self):
        """{function: {(parameter index, kind, server)}}: the parameters it sends as messages."""
        passes = collections.defaultdict(set)
        grown = True
        while grown:
            grown = False
            for node, clauses in self.clauses.items():
                for clause in clauses:
                    index = self.params(clause)
                    found = {(index[msg], kind, server if server not in index else '')
                             for kind, msg, server in clause['sends'] if msg in index}
                    for callee, args in clause['calls']:
                        for j, kind, server in passes.get(callee, ()):
                            if j < len(args) and args[j] in index:
                                found.add((index[args[j]], kind, server))
                    if not found <= passes[node]:
                        passes[node] |= found
                        grown = True
        return passes

    def named(self, module):
        """What naming a module as a value reaches: its public functions but message callbacks."""
        info = self.modules.get(module)
        if not info:
            return []
        callbacks = set(self.CALLBACKS.values()) if info['process'] else set()
        return [f'{module}.{f}' for f, clauses in info['functions'].items()
                if f not in callbacks and any(c['public'] for c in clauses)]

    def seeds(self, scripts):
        out = set()
        for script in scripts:
            entry = self.scripts.get(script, {'calls': [], 'refs': []})
            out.update(entry['calls'])
            for ref in entry['refs']:
                out.update(self.named(ref))
        return out

    def targets(self, kind, server):
        module = server[len('t:Elixir.'):] if server.startswith('t:Elixir.') else None
        named = f'{module}.{self.CALLBACKS[kind]}'
        return [named] if module and named in self.clauses else self.receivers[kind]

    def reach(self, seeds):
        """{function: parent function} of everything reachable from seeds."""
        parent = {}
        seen = set()
        stack = []

        def enter(target, tag, direct, origin):
            if target not in self.clauses:
                return
            state = (target, tag, direct)
            if state in seen or (target, '', False) in seen or (direct and (target, '', True) in seen):
                return
            seen.add(state)
            parent.setdefault(target, origin)
            stack.append(state)

        for seed in seeds:
            enter(seed, '', False, None)
        while stack:
            node, tag, direct = stack.pop()
            module = node.rsplit('.', 1)[0]
            for clause in self.clauses[node]:
                params = clause['params']
                first = params[0] if params else ''
                if tag and first.startswith('t:') and first != tag:
                    continue
                passed = tag if first.startswith('v:') else ''
                index = self.params(clause)

                def message(shape):
                    """(known tag, whether a caller accounts for it) of a sent or passed shape."""
                    if shape.startswith('t:'):
                        return shape, False
                    if passed and shape == first:
                        return passed, False
                    if shape in index and direct:
                        return '', True
                    return '', False

                def send(kind, shape, server):
                    tag_sent, elsewhere = message(shape)
                    if not elsewhere:
                        for target in self.targets(kind, server):
                            enter(target, tag_sent, False, node)

                for callee, args in clause['calls']:
                    head = args[0] if args else ''
                    enter(callee, head if head.startswith('t:') else passed if passed and head == first else '',
                          True, node)
                    for j, kind, server in self.passes.get(callee, ()):
                        send(kind, args[j] if j < len(args) else '', server)
                for kind, shape, server in clause['sends']:
                    send(kind, shape, server if server not in index else '')
                for ref in clause['refs']:
                    for target in self.named(ref):
                        enter(target, '', False, node)
            for implementer in self.implementers.get(module, ()):
                for target in self.named(implementer):
                    enter(target, '', False, node)
        return parent

    def changed_functions(self, path, lines):
        """Functions whose code changed in `path` (all of a module when a line is outside its functions)."""
        out, whole = set(), set()
        modules = self.by_file.get(path, [])
        if lines is None:
            whole.update(modules)
        for line in sorted(lines or ()):
            inside = [f'{module}.{fun}' for module in modules
                      for fun, clauses in self.modules[module]['functions'].items()
                      if any(c['range'][0] <= line <= c['range'][1] for c in clauses)]
            if inside:
                out.update(inside)
            else:
                # Attributes, `use`, `alias`, struct and docs: the innermost module around the line.
                around = sorted((m for m in modules if self.modules[m]['line'] <= line),
                                key=lambda m: self.modules[m]['line'])
                whole.update(around[-1:] if around else modules)
        return out, whole

    def compile_dependents(self, files, structs=False):
        """Files that need any of `files` at compile time (and through a struct), transitively."""
        seen, stack = set(files), list(files)
        while stack:
            current = stack.pop()
            for other in self.compile_edges['compile'].get(current, []) + \
                    (self.compile_edges['export'].get(current, []) if structs else []):
                if other not in seen:
                    seen.add(other)
                    stack.append(other)
        return seen - set(files)


def load_graph(root, env, scripts, scratch):
    """The call graph and compile-time edges of the current build, cached by beams and scripts."""
    ebin = root / env['MIX_BUILD_PATH'] / 'lib/valimc/ebin'
    digest = hashlib.sha256()
    for beam in sorted(ebin.glob('*.beam')):
        digest.update(f'{beam.name} {beam.stat().st_mtime_ns}\n'.encode())
    for script in sorted(scripts):
        digest.update(script.encode() + hashlib.sha256((root / 'scripts' / script).read_bytes()).digest())
    cached = scratch / f'call-graph-{digest.hexdigest()[:16]}.json'
    if not cached.exists():
        for old in scratch.glob('call-graph-*.json'):
            old.unlink()
        temporary = cached.with_suffix('.tmp')
        subprocess.run(['mix', 'run', '--no-compile', '--no-deps-check', '--no-start', 'scripts/call_graph.exs',
                        str(temporary), *[f'scripts/{s}' for s in sorted(scripts)]],
                       cwd=root, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        xref = subprocess.run(['mix', 'xref', 'graph', '--format', 'plain'], cwd=root, env=env, check=True,
                              capture_output=True, text=True).stdout
        data = json.loads(temporary.read_text())
        data['compile'] = parse_xref(xref)
        temporary.write_text(json.dumps(data))
        temporary.rename(cached)
    data = json.loads(cached.read_text())
    return Graph(data, data['compile'])


def parse_xref(text):
    """{'compile' | 'export': {file: [files that depend on it that way]}}."""
    dependents = {'compile': collections.defaultdict(set), 'export': collections.defaultdict(set)}
    current = None
    for line in text.splitlines():
        if not line.startswith(('|', '`', ' ')):
            current = line.strip()
            continue
        match = re.search(r'-- (\S+) \((compile|export)\)', line)
        if match and current:
            dependents[match[2]][match[1]].add(current)
    return {kind: {k: sorted(v) for k, v in edges.items()} for kind, edges in dependents.items()}


# -- Rust --------------------------------------------------------------------------------

def strip_rust(text):
    """Source with comments, strings and char literals blanked (lines and offsets kept)."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif c == '"' or (c == 'r' and re.match(r'r#*"', text[i:i + 8]) and not text[i - 1:i].isalnum()):
            if c == 'r':
                hashes = re.match(r'r(#*)"', text[i:])[1]
                end = text.find('"' + hashes, i + len(hashes) + 2)
                j = n if end < 0 else end + 1 + len(hashes)
            else:
                j = i + 1
                while j < n and text[j] != '"':
                    j += 2 if text[j] == '\\' else 1
                j += 1
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif c == "'" and re.match(r"'(\\.|[^\\'])'", text[i:i + 4]):
            j = i + len(re.match(r"'(\\.|[^\\'])'", text[i:i + 4])[0])
            out.append(' ' * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


class Native:
    def __init__(self, root):
        self.root = root
        src = root / NATIVE_CORE
        self.files = {p.relative_to(root).as_posix(): p for p in sorted(src.rglob('*.rs'))}
        self.module_of = {}
        for rel, path in self.files.items():
            parts = list(path.relative_to(src).with_suffix('').parts)
            if parts[-1] in ('lib', 'mod'):
                parts = parts[:-1]
            self.module_of[rel] = tuple(parts)
        self.file_of = {module: rel for rel, module in self.module_of.items()}
        self.uses = {rel: self.references(rel, strip_rust(path.read_text())) for rel, path in self.files.items()}
        self.users = collections.defaultdict(set)
        for rel, targets in self.uses.items():
            for target in targets:
                self.users[target].add(rel)
        self.nif_text = strip_rust((root / NATIVE_NIF).read_text())
        self.items = self.parse_items(self.nif_text)

    def resolve(self, base, path):
        """The core file a path (segments relative to `base`) names: its longest module prefix."""
        segments = list(base)
        for segment in path:
            if segment == 'super':
                segments = segments[:-1]
            elif segment == 'self':
                continue
            elif segment == 'crate':
                segments = []
            else:
                segments.append(segment)
        for length in range(len(segments), -1, -1):
            if tuple(segments[:length]) in self.file_of:
                return self.file_of[tuple(segments[:length])]
        return None

    @staticmethod
    def paths(text, prefixes):
        """Paths starting with one of `prefixes` in code and `use` trees (braces expanded)."""
        out = []
        for match in re.finditer(r'\buse\s+([^;]+);', text):
            out += expand_use(match[1])
        for match in re.finditer(r'\b((?:' + '|'.join(prefixes) + r')(?:::[A-Za-z_][A-Za-z0-9_]*)+)', text):
            out.append(match[1].split('::'))
        return [p for p in out if p and p[0] in prefixes]

    def references(self, rel, text):
        """Core files a file uses: `crate::`, `super::`, `self::` paths and paths through its own
        child modules (`use flags::BlockFlags` in a crate root or `mod.rs`)."""
        module = self.module_of[rel]
        children = {m[-1] for m in self.file_of if len(m) == len(module) + 1 and m[:len(module)] == module}
        out = set()
        for path in self.paths(text, ('crate', 'super', 'self', *children)):
            target = self.resolve(module, path)
            if target and target != rel:
                out.add(target)
        return out

    def parse_items(self, text):
        """Top-level items of the NIF crate: name -> (first line, last line, nif name or None, text)."""
        items, depth, start, lines = {}, 0, None, text.splitlines(keepends=True)
        offset_line, pending_attr = 1, None
        position = 0
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            if depth == 0 and start is None and stripped:
                start = number
            depth += line.count('{') - line.count('}')
            if depth == 0 and start is not None and (stripped.endswith(('}', ';')) or not stripped):
                block = ''.join(lines[start - 1:number])
                if not block.strip().startswith('#[') or re.search(r'\b(fn|struct|enum|impl|mod|static|const|type)\b',
                                                                   block):
                    match = re.search(r'\b(?:fn|struct|enum|mod|static|const|type|trait)\s+([A-Za-z_][A-Za-z0-9_]*)', block)
                    # `use` lines and macro calls have no name others can mention.
                    name = match[1] if match else f'@{start}'
                    header = re.sub(r'#\[[^\]]*\]', '', block).split('{')[0]
                    if re.match(r'\s*impl\b', header):
                        target = re.search(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]*)', header) or \
                            re.search(r'\bimpl(?:<[^>]*>)?\s+(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*)', header)
                        name = f'{target[1]}@impl{start}' if target else f'@{start}'
                    nif = None
                    if '#[rustler::nif' in block:
                        rename = re.search(r'rustler::nif\([^)]*name\s*=\s*"([^"]+)"', block)
                        nif = rename[1] if rename else match[1]
                    items[name] = (start, number, nif, block)
                start = None
        return items

    def imported(self):
        """Names the NIF crate's top-level `use valimc_core::...` brings in: name -> core file."""
        out = {}
        top = '\n'.join(block for _, (_, _, _, block) in self.items.items() if block.lstrip().startswith('use '))
        for path in self.paths(top, ('valimc_core',)):
            target = self.resolve((), path[1:])
            if target:
                out[path[-1]] = target
        return out

    def changed_nifs(self, changed):
        """NIF names whose code (or the core code it reaches) changed; `changed` maps paths to lines."""
        files = {p for p in changed if p in self.files}
        affected_core, stack = set(files), list(files)
        while stack:
            for user in self.users.get(stack.pop(), ()):
                if user not in affected_core:
                    affected_core.add(user)
                    stack.append(user)
        imported = self.imported()
        affected = set()
        if any(p.startswith('native/valimc_nif/') and p != NATIVE_NIF for p in changed):
            affected.update(self.items)  # another file of the NIF crate: every NIF
        if NATIVE_NIF in changed:
            lines = changed[NATIVE_NIF]
            if lines is None:
                affected.update(self.items)
            else:
                for line in lines:
                    hits = [name for name, (a, b, _, _) in self.items.items() if a <= line <= b]
                    affected.update(hits or self.items)
        names = set(self.items)
        for name, (_, _, _, block) in self.items.items():
            used = {self.resolve((), p[1:]) for p in self.paths(block, ('valimc_core',))}
            used |= {imported[w] for w in re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', block) if w in imported}
            if used & affected_core:
                affected.add(name)
        words = {name: set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', block)) for name, (_, _, _, block) in
                 self.items.items()}
        grown = True
        while grown:
            grown = False
            # An item changes when it names a changed item (an `impl` by its type's name).
            bare = {n.split('@')[0] for n in affected} - {''}
            for name in names - affected:
                if words[name] & bare:
                    affected.add(name)
                    grown = True
        return {self.items[name][2] for name in affected if self.items[name][2]}


def expand_use(tree):
    """`a::{b, c::{d, e}}` -> [[a, b], [a, c, d], [a, c, e]] (aliases and globs dropped)."""
    tree = re.sub(r'\s+as\s+[A-Za-z_][A-Za-z0-9_]*', '', tree)
    tree = re.sub(r'\s+', '', tree)

    def parse(text, prefix):
        out, depth, current = [], 0, ''
        for c in text + ',':
            if c == ',' and depth == 0:
                if current:
                    if '{' in current:
                        head, _, rest = current.partition('{')
                        head = [s for s in head.split('::') if s]
                        out += parse(rest[:-1], prefix + head)
                    else:
                        out.append(prefix + [s for s in current.split('::') if s and s != '*'])
                current = ''
                continue
            depth += (c == '{') - (c == '}')
            current += c
        return out
    return parse(tree, [])


# -- Selection ---------------------------------------------------------------------------

def stage_scripts(steps, root):
    scripts = [s[1] for s in steps if s[0] in ('check', 'app')]
    out, stack = [], list(scripts)
    while stack:
        script = stack.pop(0)
        if script in out:
            continue
        out.append(script)
        for required in re.findall(r'Code\.require_file\("([^"]+)"', (root / 'scripts' / script).read_text()):
            stack.append(pathlib.PurePosixPath(required).name)
    return out


def select(root, rev, stages, stage_names, sources, inputs, previous_stages, env, scratch, tcp, changed=None):
    """[(stage, reason)] for the stages the changes since `rev` (or `changed`) can affect."""
    changed = changes(root, rev) if changed is None else changed
    steps_of = dict(stages)
    reasons = {}

    def pick(stage, reason):
        reasons.setdefault(stage, reason)

    everything = [*stage_names, tcp]
    for path in changed:
        if any(fnmatch.fnmatch(path, pattern) for pattern in GLOBAL):
            for stage in everything:
                pick(stage, f'{path} (global input)')
    if len(reasons) == len(everything):
        return [(s, reasons[s]) for s in everything], changed
    # Stage tuples.
    if 'scripts/vanilla_stages.py' in changed:
        if previous_stages is None:
            for stage in everything:
                pick(stage, 'scripts/vanilla_stages.py (no earlier version to compare)')
        else:
            before = dict(previous_stages)
            for stage in stage_names:
                if before.get(stage) != steps_of[stage]:
                    pick(stage, 'its steps in scripts/vanilla_stages.py')
    scripts_of = {stage: stage_scripts(steps_of[stage], root) for stage in stage_names}
    classes_of = {stage: {s[1] for s in steps_of[stage] if s[0] in ('java', 'regen')} for stage in stage_names}
    classes_of[tcp] = {'VanillaOracle'}
    facts_of = {stage: {s[2] for s in steps_of[stage] if s[0] == 'same'} for stage in stage_names}
    for path in changed:
        name = pathlib.PurePosixPath(path).name
        for stage in stage_names:
            if path.startswith('scripts/') and name in scripts_of[stage]:
                pick(stage, f'{path} (its script)')
            if path in facts_of[stage]:
                pick(stage, f'{path} (compared by a same step)')
        if path.startswith('scripts/') and path.endswith('.java'):
            changed_class = pathlib.PurePosixPath(path).stem
            for stage, classes in classes_of.items():
                hit = [c for c in classes if c in sources.text and changed_class in sources.closure(c)]
                if hit:
                    pick(stage, f'{path} (oracle {hit[0]})')
        for stage, classes in classes_of.items():
            for c in classes:
                if c in sources.text and any(fnmatch.fnmatch(path, p) for p in sources.declared(c)):
                    pick(stage, f'{path} (input of {c})')
        if path in APP or fnmatch.fnmatch(path, 'config/*'):
            for stage in stage_names:
                if any(s[0] == 'app' for s in steps_of[stage]):
                    pick(stage, f'{path} (starts the application)')
    # Elixir functions, from lib/, priv/ readers and native code.
    lib = {p: lines for p, lines in changed.items() if p.startswith('lib/') and p.endswith('.ex')}
    priv = [p for p in changed if p.startswith('priv/') and p != 'priv/version.json']
    native = {p: lines for p, lines in changed.items() if p.startswith('native/') and p.endswith('.rs')}
    if not (lib or priv or native):
        return [(s, reasons[s]) for s in everything if s in reasons], changed
    all_scripts = sorted({s for scripts in scripts_of.values() for s in scripts})
    graph = load_graph(root, env, all_scripts, scratch)
    targets, whole = {}, {}
    for path, lines in lib.items():
        functions, modules = graph.changed_functions(path, lines)
        for f in functions:
            targets.setdefault(f, path)
        for m in modules:
            whole.setdefault(m, path)
        if lines is None or modules or functions:
            for dependent in graph.compile_dependents({path}, structs=lines is None or bool(modules)):
                for m in graph.by_file.get(dependent, ()):
                    whole.setdefault(m, f'{path} (needed by {dependent} at compile time)')
    for path in priv:
        base = pathlib.PurePosixPath(path).name
        readers = [f for f in (root / 'lib').rglob('*.ex') if base in f.read_text()]
        for reader in readers:
            rel = reader.relative_to(root).as_posix()
            for m in graph.by_file.get(rel, ()):
                whole.setdefault(m, f'{path} (read by {rel})')
        for stage in stage_names:
            if any(base in (root / 'scripts' / s).read_text() for s in scripts_of[stage]):
                pick(stage, f'{path} (named by its script)')
    if native:
        nifs = Native(root).changed_nifs(native)
        for nif in sorted(nifs):
            node = f'Valimc.Native.{nif}'
            targets.setdefault(node, f'{sorted(native)[0]} (NIF {nif})')
    for module, reason in whole.items():
        for node in graph.functions.get(module, ()):
            targets.setdefault(node, reason)
    if targets:
        seeds_of = {stage: graph.seeds(scripts_of[stage]) for stage in stage_names}
        seeds_of[tcp] = {f for m in TCP_SEEDS for f in graph.functions.get(m, ())}
        for stage, seeds in seeds_of.items():
            if stage in reasons:
                continue
            parent = graph.reach(seeds)
            hit = next((node for node in sorted(parent) if node in targets), None)
            if hit:
                chain, node = [], hit
                while node is not None and len(chain) < 4:
                    chain.append(node)
                    node = parent[node]
                via = ' <- '.join(chain)
                pick(stage, f'{targets[hit]}: {via}')
    return [(s, reasons[s]) for s in everything if s in reasons], changed
