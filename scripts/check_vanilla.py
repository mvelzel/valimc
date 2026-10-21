#!/usr/bin/env python3
"""Run vanilla oracle stages in parallel, longest first, and the official-codec TCP stage.

Usage: check_vanilla.py [--jobs N] [--only NAME[,NAME] ... | --changed [REV]] [--regen]
                        [--no-cache] [--no-batch] [--skip-tcp] [--list] [--audit]

`--only` takes exact stage names (comma-separated or repeated); a name with `*`, `?`
or `[` is a glob. A name that matches nothing is an error. `tcp` names the TCP stage
(plain and encrypted sessions against two ValiMC servers); it runs unless
`--skip-tcp` or an `--only` that leaves it out. `--changed [REV]` selects the stages
that the changes since REV (default: the merge base with origin/main), committed or not,
can affect, and prints why (`stage_changes.py`); with `--list` it only prints them.

Vanilla's side of each stage comes from the oracle cache (`oracle_cache.py`) when its
key is known; ValiMC's side always runs. `--no-cache` runs every oracle again (with a
private cache, so identical runs inside one run still happen once). Fact extraction
(`regen` steps) runs only with `--regen`; without it a regeneration step whose key is
not cached is reported as not verified, and its comparisons are skipped.

Stages live in `vanilla_stages.py`. Logs go to `.local/vanilla-checks/<stage>.log`.
Stage durations are kept in the main checkout's `.local/oracle-cache/timings.json`
(shared by every worktree) and order the next run, longest first. A run of more than
a few stages takes a heavy-job slot (`scripts/heavy.py`) unless it already holds one.
All failures are collected and reported; the exit status is non-zero if any failed.
"""
import argparse, concurrent.futures as cf, contextlib, difflib, fcntl, fnmatch, hashlib, json, os, pathlib, \
    shutil, socket, subprocess, sys, tempfile, threading, time, traceback
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import heavy, java_tool, oracle_cache, stage_changes
from vanilla_stages import ALIASES, ESTIMATES, HELPERS, INPUTS, STAGES, THREADED

root = java_tool.root
logs = root / '.local/vanilla-checks'
TCP = 'tcp'
ORACLE_KINDS = ('java', 'regen')
MOVED = {'directory_recovery': 'an ExUnit test: mix test test/directory_recovery_test.exs'}
# Warm stages under SMALL_STAGE seconds run in groups of up to GROUP_STAGES stages and
# GROUP_SECONDS estimated seconds, their checks in one BEAM.
SMALL_STAGE, GROUP_STAGES, GROUP_SECONDS = 40, 10, 90
# Runs of up to this many stages are small enough to skip the heavy-job slot.
HANDFUL = 6


def toolchain():
    """The pinned Elixir and Erlang ahead of asdf's shims, which cost seconds per `mix` call on a
    loaded host (8 s against 2 s, October 2026), with the Mix home the Elixir shim would set."""
    env, found = {}, []
    for tool in ('elixir', 'erlang'):
        try:
            where = subprocess.run(['asdf', 'where', tool], cwd=root, capture_output=True, text=True,
                                   check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return env  # no asdf: whatever PATH finds
        found.append(where + '/bin')
        if tool == 'elixir':
            env['MIX_HOME'] = os.environ.get('MIX_HOME') or where + '/.mix'
            env['MIX_ARCHIVES'] = os.environ.get('MIX_ARCHIVES') or env['MIX_HOME'] + '/archives'
    env['PATH'] = os.pathsep.join(found + [os.environ.get('PATH', '')])
    return env


# A private build compiled once up front: concurrent source edits cannot change a run.
mix_env = dict(os.environ, MIX_BUILD_PATH=str(root / '.local/vanilla-checks/_build'),
               VALIMC_BUILD_EMBEDDED='1', **toolchain())
# One all-core oracle at a time (cold ones also get their own lane in `main`), sized to the
# cores the other jobs leave free.
all_core = threading.Lock()


def shared_dir():
    """The main checkout's `.local/oracle-cache`, shared by every worktree."""
    path = java_tool.shared
    path.mkdir(parents=True, exist_ok=True)
    return path


def names_of(kind, target, args):
    """The scratch names (`@x` without the `@`) a step mentions."""
    return [a[1:] for a in ([target] if kind == 'same' else []) + list(args) if a.startswith('@')]


def related(a, b):
    return a == b or a.startswith(b + '/') or b.startswith(a + '/')


def plan(steps):
    """Per oracle step: the scratch names it reads, those it writes, and whether a ValiMC step
    may have written anything it reads (then it is a verify step and never cached)."""
    out = {}
    for index, (kind, target, *args) in enumerate(steps):
        if kind not in ORACLE_KINDS:
            continue
        mine = names_of(kind, target, args)
        earlier = [(steps[j][0], names_of(steps[j][0], steps[j][1], steps[j][2:])) for j in range(index)]
        given = [a for a in mine if any(related(a, b) for _, names in earlier for b in names)]
        tainted = any(related(a, b) for a in mine for k, names in earlier if k in ('check', 'app') for b in names)
        out[index] = {'given': given, 'outputs': [a for a in mine if a not in given], 'verify': tainted}
    return out


def audit(sources):
    """Every oracle and checker is registered; inputs are declared; regeneration only feeds comparisons."""
    used = {step[1] for _, steps in STAGES for step in steps if step[0] in ('java', 'regen', 'check', 'app')}
    problems = []
    problems += [f'UNREGISTERED: scripts/{p.name} is not in vanilla_stages.py'
                 for p in sorted((root / 'scripts').glob('*.java')) if p.stem not in used and p.stem not in HELPERS]
    problems += [f'UNREGISTERED: scripts/{p.name} is not in vanilla_stages.py'
                 for p in sorted((root / 'scripts').glob('check_*.exs')) if p.name not in used]
    problems += [f'UNKNOWN: vanilla_stages.py references missing {name}' for name in sorted(used)
                 if not (root / 'scripts' / name).exists() and not (root / 'scripts' / (name + '.java')).exists()]
    names = [name for name, _ in STAGES]
    problems += [f'DUPLICATE: stage name {name} is used twice or reserved'
                 for name in sorted({n for n in names if names.count(n) > 1 or n == TCP})]
    for name in sorted(sources.text):
        for literal in sources.undeclared(name):
            problems.append(f'UNDECLARED INPUT: scripts/{name}.java reads {literal}; add it to INPUTS["{name}"]')
    for name, patterns in sorted(INPUTS.items()):
        if name not in sources.text:
            problems.append(f'UNKNOWN: INPUTS names missing oracle {name}')
        for pattern in patterns:
            if not oracle_cache.expand(root, pattern, [heavy.main_checkout()])[1]:
                problems.append(f'STALE INPUT: INPUTS["{name}"] pattern {pattern} matches no file')
    for stage, steps in STAGES:
        plans = plan(steps)
        for index, (kind, target, *args) in enumerate(steps):
            if kind != 'regen':
                continue
            if plans[index]['verify']:
                problems.append(f'REGEN: {stage} step {index} ({target}) reads ValiMC output')
            for later_kind, later_target, *later_args in steps[index + 1:]:
                if later_kind not in ('same', 'regen') and any(
                        related(a, b) for a in plans[index]['outputs']
                        for b in names_of(later_kind, later_target, later_args)):
                    problems.append(f'REGEN: {stage} uses {target} output in a {later_kind} step; '
                                    'regeneration may only feed comparisons')
    problems += [f'SHAPE BLOCKS: the worldgen code places {name}; add it to scripts/shape_blocks.txt '
                 '(then --regen --only worldgen_shapes)' for name in shape_blocks_missing()]
    for problem in problems:
        print(problem, file=sys.stderr)
    return not problems


def shape_blocks_missing():
    """Blocks ValiMC's worldgen code names (as ShapeOracle once scanned it) that its list lacks."""
    import re
    blocks = {row[0] for row in json.loads((root / 'priv/registry/blocks.json').read_text())['blocks']}
    listed = {line.strip() for line in (root / 'scripts/shape_blocks.txt').read_text().splitlines()
              if line.strip() and not line.startswith('#')}
    named = re.compile(r'(?:default_state|block)\("([a-z0-9_]+)"\)')
    literal = re.compile(r'"([a-z0-9_]+)(?:\[[a-z0-9_=,]*\])?"')
    found = set()
    worldgen = root / 'native/valimc_core/src/worldgen'
    for path in worldgen.glob('*.rs'):
        found |= set(named.findall(path.read_text()))
    for path in (worldgen / 'structure').glob('*.rs'):
        found |= set(literal.findall(path.read_text()))
    return sorted((found & blocks) - listed)


def select(patterns, skip_tcp):
    """Stage names for `--only` patterns (exact, or globs); exits when a pattern matches nothing."""
    names = [name for name, _ in STAGES] + [TCP]
    if not patterns:
        return [name for name in names if name != TCP or not skip_tcp]
    chosen, unmatched = set(), []
    for pattern in (p.strip() for value in patterns for p in value.split(',')):
        if not pattern:
            continue
        if pattern in MOVED:
            sys.exit(f'check_vanilla: {pattern} is {MOVED[pattern]}')
        found = fnmatch.filter(names, pattern) if any(c in pattern for c in '*?[') else \
            [pattern] if pattern in names else [ALIASES[pattern]] if pattern in ALIASES else []
        if not found:
            close = difflib.get_close_matches(pattern, names, n=3, cutoff=0.6)
            unmatched.append(pattern + (f' (did you mean {", ".join(close)}?)' if close else ''))
        chosen.update(found)
    if unmatched:
        sys.exit('check_vanilla: no stage matches ' + '; '.join(unmatched))
    return [name for name in names if name in chosen and not (name == TCP and skip_tcp)]


class Timings:
    """Per-stage wall seconds of the last cold and warm runs, shared by every worktree."""

    def __init__(self):
        self.path = shared_dir() / 'timings.json'
        try:
            self.known = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.known = {}
        self.measured = {}

    def estimate(self, name, warm=False):
        entry = self.known.get(name, {})
        if warm and 'warm' in entry:
            return entry['warm']
        return entry.get('cold', entry.get('seconds', ESTIMATES.get(name, 15)))

    def record(self, name, seconds, warm):
        entry = dict(self.known.get(name, {}))
        entry.pop('seconds', None)
        entry['warm' if warm else 'cold'] = round(seconds, 1)
        entry['at'] = int(time.time())
        self.measured[name] = entry

    def save(self):
        """Merges this run's durations into the shared file (locked, atomic replace)."""
        if not self.measured:
            return
        with open(self.path.with_suffix('.lock'), 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                known = json.loads(self.path.read_text())
            except (OSError, ValueError):
                known = {}
            for name, entry in self.measured.items():
                known[name] = {**known.get(name, {}), **entry}
                known[name].pop('seconds', None)
            temporary = self.path.with_name(f'.timings-{os.getpid()}.json')
            temporary.write_text(json.dumps(known, indent=1, sort_keys=True) + '\n')
            os.replace(temporary, self.path)


def scratch_state(work):
    """Top-level scratch entries (oracle working directories aside) and their modification times."""
    return {p.name: p.stat().st_mtime_ns for p in work.iterdir() if not p.name.startswith('.cwd-')}


class Stage:
    """One stage's run: scratch directory, log, plans and results so far."""

    def __init__(self, name, steps, work, log_path, log, plans):
        self.name, self.steps, self.work, self.log_path, self.log, self.plans = \
            name, steps, work, log_path, log, plans
        self.ok, self.warm = True, True
        self.skipped, self.unverified, self.pending = [], 0, []
        self.check_seconds = self.prefix_seconds = 0.0


class Runner:
    def __init__(self, opts, java, cp, identity, sources, cache):
        self.opts, self.java, self.cp, self.identity = opts, java, cp, identity
        self.sources, self.cache = sources, cache
        self.input_memo = {}
        self.memo_guard = threading.Lock()
        self.unverified = []

    def java_command(self, target, args):
        if target not in THREADED:
            return [self.java, *java_tool.JVM_FLAGS, '-cp', self.cp, target, *args]
        threads = max(2, (os.cpu_count() or 2) - self.opts.jobs + 1)
        return [self.java, *java_tool.JVM_FLAGS, f'-XX:ActiveProcessorCount={threads}', '-cp', self.cp, target, *args]

    def declared_inputs(self, target):
        """(relative path, absolute path, digest) of every repo file the oracle may read."""
        out = []
        for pattern in self.sources.declared(target):
            base, files = oracle_cache.expand(root, pattern, [heavy.main_checkout()])
            for relative in files:
                with self.memo_guard:
                    digest = oracle_cache.file_digest(base / relative, self.input_memo)
                out.append((relative, base / relative, digest))
        return out

    def key(self, target, args, given, work):
        payload = {
            'format': oracle_cache.FORMAT, 'runtime': self.identity, 'class': target,
            'sources': self.sources.closure_digest(target),
            'inputs': [(relative, digest) for relative, _, digest in self.declared_inputs(target)],
            'env': {name: os.environ.get(name) for name in self.sources.environment(target)},
            'args': list(args),
            'given': {name: oracle_cache.tree_digest(work / name, work) for name in sorted(given)},
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()

    def sandbox(self, work, index, target):
        """A working directory holding only the oracle's declared repo inputs (as links), so an
        undeclared read fails instead of escaping the cache key."""
        cwd = work / f'.cwd-{index}'
        cwd.mkdir()
        for relative, absolute, _ in self.declared_inputs(target):
            link = cwd / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(absolute.resolve())
        return cwd

    def oracle(self, stage, index, kind, target, args, step_plan, work, log, log_path):
        """Runs or restores one oracle step; returns 'cached', 'ok', 'failed' or 'skipped'."""
        resolved = [str(work / a[1:]) if a.startswith('@') else a for a in args]
        shown = ' '.join([target, *args])
        cacheable = not step_plan['verify']
        key = self.key(target, args, step_plan['given'], work) if cacheable else None
        with self.cache.claim(key) if key else contextlib.nullcontext():
            entry = self.cache.lookup(key) if key else None
            if entry:
                try:
                    meta = self.cache.restore(entry, work)
                except (OSError, ValueError):
                    meta = None  # pruned or damaged meanwhile: run it
                if meta:
                    self.cache.hits += 1
                    self.cache.saved += meta['seconds']
                    log.write(f'$ {shown}  [cached {key[:12]}, {meta["seconds"]:.0f}s saved]\n')
                    log.write((entry / 'log.txt').read_text())
                    log.flush()
                    return 'cached'
            if kind == 'regen' and not self.opts.regen:
                log.write(f'$ {shown}  [not verified: no cached extraction for this key; run with --regen]\n')
                log.flush()
                return 'skipped'
            log.write(f'$ {shown}{"" if cacheable else "  [verify: reads ValiMC output, never cached]"}\n')
            log.flush()
            start = log_path.stat().st_size
            began = time.monotonic()
            before = scratch_state(work)
            with all_core if target in THREADED else contextlib.nullcontext():
                result = subprocess.run(self.java_command(target, resolved), cwd=self.sandbox(work, index, target),
                                        stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                return 'failed'
            if key:
                self.cache.misses += 1
                with log_path.open() as reread:
                    reread.seek(start)
                    text = reread.read()
                # Outputs are what the arguments name plus anything else the run created or changed
                # in the scratch directory (`PlayerExperienceOracle OUT` also writes OUT.contact.json).
                after = scratch_state(work)
                made = [name for name, stamp in after.items() if before.get(name) != stamp]
                refused = self.cache.store(key, work, sorted(set(step_plan['outputs']) | set(made)), text,
                                           time.monotonic() - began, f'{stage}: {shown}')
                if refused:
                    log.write(f'[not cached: {refused}]\n')
            return 'ok'

    def open(self, name, steps):
        log_path = logs / f'{name}.log'
        log_path.write_text('')
        work = pathlib.Path(tempfile.mkdtemp(prefix=f'valimc-oracle-{name}-'))
        # Append mode: batched checks append to the same file from another process.
        return Stage(name, steps, work, log_path, log_path.open('a'), plan(steps))

    def close(self, state):
        state.log.close()
        shutil.rmtree(state.work, ignore_errors=True)

    def prefix(self, state):
        """Runs a stage's steps, deferring checks (in order) until a step needs their output: a
        verify or app step, or one naming what a deferred check names. Sets `state.ok`."""
        log = state.log
        for index, (kind, target, *args) in enumerate(state.steps):
            mine = names_of(kind, target, args)
            if state.pending and kind != 'check' and (
                    kind == 'app' or (kind in ORACLE_KINDS and state.plans[index]['verify']) or any(
                    related(a, b) for a in mine for _, _, theirs in state.pending for b in theirs)):
                if not self.flush([state]):
                    return
            resolved = [str(state.work / a[1:]) if a.startswith('@') else a for a in args]
            if kind == 'check':
                state.pending.append((target, resolved, mine))
                continue
            if kind in ORACLE_KINDS:
                outcome = self.oracle(state.name, index, kind, target, args, state.plans[index], state.work, log,
                                      state.log_path)
                state.warm = state.warm and (outcome == 'cached' or state.plans[index]['verify'])
                if outcome == 'failed':
                    state.ok = False
                    return
                if outcome == 'skipped':
                    state.skipped += state.plans[index]['outputs']
                    state.unverified += 1
                continue
            if kind == 'same':
                if any(related(target[1:], s) for s in state.skipped):
                    log.write(f'SKIP: {target} against {args[0]} (its extraction was not run)\n')
                    continue
                generated, committed = json.loads((state.work / target[1:]).read_text()), \
                    json.loads((root / args[0]).read_text())
                if generated != committed:
                    log.write(f'FAIL: generated {target} differs from committed {args[0]}\n')
                    state.ok = False
                    return
                log.write(f'PASS: {target} matches {args[0]}\n')
                continue
            if kind != 'app':
                raise ValueError(kind)
            cmd = ['mix', 'run', '--no-compile', '--no-deps-check', f'scripts/{target}', *resolved]
            log.write(f'$ {" ".join(cmd)}\n')
            log.flush()
            env = dict(mix_env, VALIMC_PORT='0', VALIMC_WORLD=str(state.work / 'world'))
            if subprocess.run(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT).returncode:
                state.ok = False
                return

    def alone(self, state, target, resolved):
        cmd = ['mix', 'run', '--no-compile', '--no-deps-check', '--no-start', f'scripts/{target}', *resolved]
        state.log.write(f'$ {" ".join(cmd)}\n')
        state.log.flush()
        return subprocess.run(cmd, cwd=root, env=mix_env, stdout=state.log, stderr=subprocess.STDOUT).returncode == 0

    def flush(self, states):
        """Runs the deferred checks of `states`, several to a BEAM when there are several. A check
        that fails there reruns, with the rest of its stage's, in a BEAM of its own, whose result
        counts. Returns whether every stage passed."""
        states = [s for s in states if s.pending]
        batched = [s for s in states if not self.opts.no_batch and not any(
            'System.halt' in (root / 'scripts' / target).read_text() for target, _, _ in s.pending)]
        if sum(len(s.pending) for s in batched) < 2:
            batched = []
        results = {}
        if batched:
            for s in batched:
                s.log.flush()
            with tempfile.TemporaryDirectory(prefix='valimc-checks-') as scratch:
                manifest, out = pathlib.Path(scratch) / 'manifest.json', pathlib.Path(scratch) / 'results.jsonl'
                entries = [{'script': f'scripts/{target}', 'args': resolved, 'log': str(s.log_path)}
                           for s in batched for target, resolved, _ in s.pending]
                manifest.write_text(json.dumps(entries))
                with (logs / f'beam-{batched[0].name}.log').open('w') as beam:
                    subprocess.run(['mix', 'run', '--no-compile', '--no-deps-check', '--no-start',
                                    'scripts/run_checks.exs', str(manifest), str(out)],
                                   cwd=root, env=mix_env, stdout=beam, stderr=subprocess.STDOUT)
                rows = [json.loads(line) for line in out.read_text().splitlines()] if out.exists() else []
            for s in batched:
                mine = [row for row in rows if row['log'] == str(s.log_path)]
                results[s.name] = len(mine) == len(s.pending) and all(row['ok'] for row in mine)
                s.check_seconds += sum(row['seconds'] for row in mine)
        for s in states:
            if results.get(s.name):
                s.pending = []
                continue
            if s.name in results:
                s.log.write('[a check failed in a shared BEAM; this stage\'s checks rerun alone, and that counts]\n')
            began = time.monotonic()
            for target, resolved, _ in s.pending:
                if not self.alone(s, target, resolved):
                    s.ok = False
                    break
            s.check_seconds += time.monotonic() - began
            s.pending = []
        return all(s.ok for s in states)

    def stage(self, name, steps):
        state = self.open(name, steps)
        try:
            self.prefix(state)
            if state.ok:
                self.flush([state])
            return [state]
        finally:
            self.close(state)

    def group(self, names, steps_of):
        """Small stages together: every oracle step first, then all their checks in one BEAM."""
        states = [self.open(name, steps_of[name]) for name in names]
        try:
            for state in states:
                began = time.monotonic()
                self.prefix(state)
                state.prefix_seconds = time.monotonic() - began
            self.flush([s for s in states if s.ok])
            return states
        finally:
            for state in states:
                self.close(state)

    def tcp(self):
        """Plain and encrypted official-codec sessions against isolated servers."""
        ok = True
        with tempfile.TemporaryDirectory(prefix='valimc-oracle-tcp-') as world, \
                (logs / f'{TCP}.log').open('w') as summary:
            for mode, encrypted in [('plain', False), ('encrypted', True)]:
                with socket.socket() as probe:
                    probe.bind(('127.0.0.1', 0))
                    port = probe.getsockname()[1]
                env = dict(mix_env, VALIMC_PORT=str(port), VALIMC_WORLD=str(pathlib.Path(world) / mode),
                           VALIMC_ENCRYPTION=str(encrypted).lower(), VALIMC_ONLINE_MODE='false',
                           VALIMC_GAME_MODE='creative', VALIMC_RESPAWN_RADIUS='0')
                log_path = logs / f'tcp-{mode}-server.log'
                with log_path.open('w') as log:
                    server = subprocess.Popen(['mix', 'run', '--no-compile', '--no-deps-check', '--no-halt'], cwd=root,
                                              env=env, stdout=log, stderr=subprocess.STDOUT)
                    try:
                        # A loaded host can take a minute to boot the server; a crash ends the wait.
                        deadline = time.monotonic() + 180
                        while time.monotonic() < deadline:
                            if server.poll() is not None or 'listening on' in log_path.read_text():
                                break
                            time.sleep(0.1)
                        if server.poll() is not None or 'listening on' not in log_path.read_text():
                            summary.write(f'FAIL tcp-{mode}: server did not start; see {log_path.name}\n')
                            ok = False
                            continue
                        with (logs / f'tcp-{mode}.log').open('w') as client_log:
                            result = subprocess.run(
                                [self.java, *java_tool.JVM_FLAGS, '-cp', self.cp, 'VanillaOracle', str(port), mode],
                                cwd=root, stdout=client_log, stderr=subprocess.STDOUT)
                        summary.write(f'{"PASS" if result.returncode == 0 else "FAIL"} tcp-{mode}; '
                                      f'see tcp-{mode}.log\n')
                        ok = ok and result.returncode == 0
                    finally:
                        server.terminate()
                        try:
                            server.wait(timeout=20)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait()
        return ok

    def probably_warm(self, steps):
        """Whether the stage's first oracle step (if it reads nothing earlier) is cached."""
        plans = plan(steps)
        for index, (kind, target, *args) in enumerate(steps):
            if kind in ORACLE_KINDS:
                if plans[index]['given'] or plans[index]['verify']:
                    return False
                return self.cache.lookup(self.key(target, args, [], root)) is not None
        return True


def changed_stages(opts, sources, timings):
    """Stages the changes since `--changed` REV can affect, printed with the reason for each."""
    rev = opts.changed or stage_changes.base_revision(root)
    try:
        text = stage_changes.git(root, 'show', f'{rev}:scripts/vanilla_stages.py')
        previous = {}
        exec(compile(text, 'vanilla_stages.py', 'exec'), previous)
        previous = previous['STAGES']
    except Exception:
        previous = None
    stage_names = [name for name, _ in STAGES]
    chosen, changed = stage_changes.select(root, rev, STAGES, stage_names, sources, INPUTS, previous, mix_env,
                                           logs, TCP)
    chosen = [(name, why) for name, why in chosen if not (name == TCP and opts.skip_tcp)]
    short = stage_changes.git(root, 'rev-parse', '--short', rev).strip()
    seconds = sum(timings.estimate(name, True) for name, _ in chosen)
    print(f'{len(changed)} changed paths since {short}; {len(chosen)} of {len(stage_names) + 1} stages selected '
          f'(about {seconds / 60:.0f} stage-minutes warm)')
    for name, why in chosen:
        print(f'  {name}: {why}')
    return [name for name, _ in chosen]


def schedule(names, steps_of, warm_guess, estimate, no_batch):
    """Units of work, longest first: single stages, and groups of small warm stages without
    verify or app steps (their oracle steps are restores, their checks share one BEAM)."""
    def groupable(name):
        steps = steps_of.get(name)
        return (not no_batch and steps and warm_guess[name] and estimate[name] < SMALL_STAGE
                and all(kind != 'app' for kind, *_ in steps) and not any(p['verify'] for p in plan(steps).values()))
    small = sorted((n for n in names if groupable(n)), key=estimate.get, reverse=True)
    units = [[n] for n in names if n not in small]
    group = []
    for name in small:
        if group and (len(group) >= GROUP_STAGES or sum(map(estimate.get, group)) + estimate[name] > GROUP_SECONDS):
            units.append(group)
            group = []
        group.append(name)
    if group:
        units.append(group)
    return sorted(units, key=lambda unit: sum(map(estimate.get, unit)), reverse=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument('--only', nargs='+', action='extend', metavar='NAME',
                        help='exact stage names, comma-separated or repeated; globs only with * ? [')
    parser.add_argument('--changed', nargs='?', const='', metavar='REV',
                        help='the stages changes since REV (default: merge base with origin/main) affect')
    parser.add_argument('--regen', action='store_true', help='also run fact extraction whose key is not cached')
    parser.add_argument('--no-cache', action='store_true', help='run every oracle again (a private, empty cache)')
    parser.add_argument('--no-batch', action='store_true', help='one BEAM per check script')
    parser.add_argument('--skip-tcp', action='store_true')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--audit', action='store_true', help='only check stage registration and declared inputs')
    opts = parser.parse_args()
    sources = oracle_cache.Sources(root, INPUTS)
    if not audit(sources):
        return 1
    if opts.audit:
        print(f'PASS: {len(STAGES)} stages register every oracle and checker; every oracle declares its inputs')
        return 0
    timings = Timings()
    if opts.changed is not None:
        if opts.only:
            sys.exit('check_vanilla: --only and --changed do not combine')
        logs.mkdir(parents=True, exist_ok=True)
        subprocess.run(['mix', 'compile'], cwd=root, env=mix_env, check=True)
        names = changed_stages(opts, sources, timings)
        if opts.list or not names:
            return 0
    elif opts.list:
        for name, steps in STAGES:
            print(f'{name} ({timings.estimate(name):.0f}s)', ' '.join(s[1] for s in steps if s[0] != 'same'))
        print(f'{TCP} ({timings.estimate(TCP):.0f}s) VanillaOracle against plain and encrypted servers')
        return 0
    else:
        names = select(opts.only, opts.skip_tcp)
    steps_of = dict(STAGES)
    slot = None
    if len(names) > HANDFUL and not os.environ.get('VALIMC_HEAVY_HELD'):
        slot = heavy.acquire(sys.argv)
        os.environ['VALIMC_HEAVY_HELD'] = mix_env['VALIMC_HEAVY_HELD'] = '1'
        os.nice(heavy.NICENESS)
    logs.mkdir(parents=True, exist_ok=True)
    if opts.changed is None:
        subprocess.run(['mix', 'compile'], cwd=root, env=mix_env, check=True)
    java_home = java_tool.find_java_home()
    identity = java_tool.runtime(java_home)
    java, cp = java_tool.compile_tools(java_home, identity)
    private = tempfile.TemporaryDirectory(prefix='valimc-oracle-cache-') if opts.no_cache else None
    limit = float(os.environ.get('VALIMC_ORACLE_CACHE_GB', '8')) * 2 ** 30
    cache = oracle_cache.Cache(pathlib.Path(private.name) if private else shared_dir(), limit)
    runner = Runner(opts, java, cp, identity, sources, cache)
    started = time.monotonic()
    failed, unverified = [], []
    for old in logs.glob('beam-*.log'):
        old.unlink()
    warm_guess = {name: name != TCP and runner.probably_warm(steps_of[name]) for name in names}
    estimate = {name: timings.estimate(name, warm_guess[name]) for name in names}
    # The TCP sessions run last, alone: their packet waits time out beside heavy stages.
    units = schedule([n for n in names if n != TCP], steps_of, warm_guess, estimate, opts.no_batch)

    def run(unit):
        try:
            return attempt(unit)
        except Exception:
            # A runner bug fails its stages, with the traceback in their logs, not the run.
            for name in unit:
                with (logs / f'{name}.log').open('a') as log:
                    log.write(traceback.format_exc())
            return [(name, False, False, 0, 0.0) for name in unit]

    def attempt(unit):
        begun = time.monotonic()
        if unit == [TCP]:
            return [(TCP, runner.tcp(), False, 0, time.monotonic() - begun)]
        if len(unit) == 1:
            [state] = runner.stage(unit[0], steps_of[unit[0]])
            return [(state.name, state.ok, state.warm, state.unverified, time.monotonic() - begun)]
        return [(s.name, s.ok, s.warm, s.unverified, s.prefix_seconds + s.check_seconds)
                for s in runner.group(unit, steps_of)]

    # Cold all-core stages take a lane of their own, so they wait for one another
    # without holding the other jobs' slots.
    threaded = [unit for unit in units if any(
        not warm_guess.get(name, True) and any(s[0] in ORACLE_KINDS and s[1] in THREADED for s in steps_of[name])
        for name in unit if name != TCP)]
    lane = cf.ThreadPoolExecutor(1) if threaded and opts.jobs > 1 else None
    def report(results):
        for name, ok, warm, skipped, seconds in results:
            if ok and not skipped:
                timings.record(name, seconds, warm)
            note = f', {skipped} regeneration step{"s" * (skipped > 1)} not verified' if skipped else ''
            print(f'{"PASS" if ok else "FAIL"} {name} ({seconds:.1f}s{note})', flush=True)
            if not ok:
                failed.append(name)
            elif skipped:
                unverified.append(name)

    with cf.ThreadPoolExecutor(opts.jobs - 1 if lane else opts.jobs) as pool:
        futures = [(lane if lane and unit in threaded else pool).submit(run, unit) for unit in units]
        for future in cf.as_completed(futures):
            report(future.result())
    if lane:
        lane.shutdown()
    if TCP in names:
        report(run([TCP]))
    timings.save()
    if private:
        private.cleanup()
    else:
        total, removed = cache.prune()
        print(f'oracle cache: {cache.hits} hits ({cache.saved:.0f}s of oracle time reused), {cache.misses} runs '
              f'stored; {total / 2 ** 30:.1f} GB' + (f', {removed} old entries pruned' if removed else ''))
    print(f'{len(names) - len(failed)}/{len(names)} stages passed in {time.monotonic() - started:.0f}s; '
          f'logs in {logs.relative_to(root)}')
    if unverified:
        print(f'not verified (no cached extraction; run --regen --only {",".join(sorted(unverified))}): '
              f'{", ".join(sorted(unverified))}')
    for name in sorted(failed):
        print(f'  FAILED {name}: {logs.relative_to(root)}/{name}.log', file=sys.stderr)
    if slot:
        slot.close()
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
