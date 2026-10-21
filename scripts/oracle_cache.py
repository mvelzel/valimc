"""Content-keyed cache of vanilla oracle runs, shared by every worktree.

Vanilla's side of a stage is a function of the pinned jar and libraries, the JDK and
its flags, the oracle's own Java sources and every source it references (its
closure), its arguments, the environment variables the closure reads, the repo files
it declares (`INPUTS` in `vanilla_stages.py`) and the earlier oracle outputs it is
given. A key hashes all of them; an entry holds the outputs, the step's log and its
duration. Steps that read anything a ValiMC step wrote are never cached.

Entries live in the main checkout's `.local/oracle-cache/steps/` and are written to a
temporary directory first, then renamed into place, so readers only ever see whole
entries. Outputs that name the stage's scratch directory are stored with a
placeholder and relocated on restore. The cache keeps at most
`VALIMC_ORACLE_CACHE_GB` (default 8) and drops the least recently used entries.
"""
import fnmatch, functools, hashlib, json, os, pathlib, re, shutil, subprocess, threading, time, uuid

FORMAT = 'valimc-oracle-cache-1'
PLACEHOLDER = '@@VALIMC_ORACLE_WORK@@'
TEXT_SUFFIXES = {'.json', '.jsonl', '.txt', '.properties', '.log', '.csv', ''}
REPO_PATH = re.compile(r'"((?:priv|native|lib|scripts|research|config|test|docs|bench)/[^"\s:]*)')
IDENTIFIER = re.compile(r'\b[A-Z][A-Za-z0-9_]*\b')
GETENV = re.compile(r'getenv\(\s*"([^"]+)"\s*\)')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Sources:
    """The oracle sources in `scripts/`, their reference closure and declared repo inputs."""

    def __init__(self, root, inputs):
        self.root = root
        self.inputs = inputs
        self.text = {p.stem: p.read_text() for p in sorted((root / 'scripts').glob('*.java'))}
        self.digest = {name: sha256(text.encode()) for name, text in self.text.items()}
        # A source depends on every oracle class it names (comments included): over-keying
        # costs a rerun, under-keying a stale pass.
        self.references = {name: {word for word in IDENTIFIER.findall(text) if word in self.text and word != name}
                           for name, text in self.text.items()}

    @functools.lru_cache(maxsize=None)
    def closure(self, name):
        seen, stack = {name}, [name]
        while stack:
            for other in self.references.get(stack.pop(), ()):
                if other not in seen:
                    seen.add(other)
                    stack.append(other)
        return frozenset(seen)

    def declared(self, name):
        """Repo input patterns of a class and of every class in its closure."""
        return sorted({pattern for other in self.closure(name) for pattern in self.inputs.get(other, ())})

    def environment(self, name):
        return sorted({var for other in self.closure(name) for var in GETENV.findall(self.text[other])})

    def undeclared(self, name):
        """Repo paths a class's source names that none of its declared inputs cover."""
        patterns = self.declared(name)
        out = []
        for literal in sorted(set(REPO_PATH.findall(self.text[name]))):
            if not any(literal == p or fnmatch.fnmatch(literal, p) or p.startswith(literal) for p in patterns):
                out.append(literal)
        return out

    def closure_digest(self, name):
        return sha256(json.dumps(sorted((other, self.digest[other]) for other in self.closure(name))).encode())


def expand(root, pattern, fallbacks=()):
    """Files a declared input pattern names, relative to `root` (or a fallback root)."""
    for base in (root, *fallbacks):
        files = sorted(p for p in base.glob(pattern) if p.is_file())
        if files:
            return base, [p.relative_to(base).as_posix() for p in files]
    return root, []


def file_digest(path, memo=None):
    """sha256 of a file; `memo` maps (path, size, mtime) to digests for large stable files."""
    stat = path.stat()
    token = f'{path}|{stat.st_size}|{stat.st_mtime_ns}'
    if memo is not None and token in memo:
        return memo[token]
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    value = digest.hexdigest()
    if memo is not None:
        memo[token] = value
    return value


def work_variants(work):
    """Spellings of a scratch directory that outputs may embed (macOS /var vs /private/var)."""
    return sorted({str(work), str(work.resolve())}, key=len, reverse=True)


def is_text(path):
    return path.suffix.lower() in TEXT_SUFFIXES


def tree_digest(path, work):
    """Content digest of a file or directory, with the scratch directory normalized."""
    digest = hashlib.sha256()
    files = [path] if path.is_file() else sorted(p for p in path.rglob('*') if p.is_file())
    for file in files:
        data = file.read_bytes()
        if is_text(file):
            for variant in work_variants(work):
                data = data.replace(variant.encode(), PLACEHOLDER.encode())
        digest.update(file.relative_to(path).as_posix().encode() + b'\0' + sha256(data).encode())
    return digest.hexdigest()


class Cache:
    def __init__(self, directory, limit_bytes):
        self.directory = directory
        self.steps = directory / 'steps'
        self.limit = limit_bytes
        self.steps.mkdir(parents=True, exist_ok=True)
        self.inflight = {}
        self.guard = threading.Lock()
        self.hits = self.misses = self.stored = 0
        self.saved = 0.0

    def entry(self, key):
        return self.steps / key[:2] / key

    def claim(self, key):
        """A per-key lock: the second stage asking for a key waits for the first to store it."""
        with self.guard:
            return self.inflight.setdefault(key, threading.Lock())

    def lookup(self, key):
        path = self.entry(key)
        if not (path / 'meta.json').exists():
            return None
        try:
            os.utime(path / 'meta.json')
        except OSError:
            return None
        return path

    def restore(self, entry, work):
        meta = json.loads((entry / 'meta.json').read_text())
        for relative in meta['outputs']:
            source, target = entry / 'files' / relative, work / relative
            if target.exists():
                shutil.rmtree(target) if target.is_dir() else target.unlink()
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)
        for relative in meta['relocated']:
            path = work / relative
            path.write_text(path.read_text().replace(PLACEHOLDER, str(work)))
        return meta

    def store(self, key, work, outputs, log_text, seconds, description):
        """Copies outputs (and scratch entries they name) into a new entry; None if they cannot move."""
        variants = work_variants(work)
        chosen, pending = set(), list(outputs)
        while pending:
            relative = pending.pop()
            if relative in chosen or not (work / relative).exists():
                continue
            chosen.add(relative)
            path = work / relative
            for file in [path] if path.is_file() else sorted(p for p in path.rglob('*') if p.is_file()):
                data = file.read_bytes()
                if not any(v.encode() in data for v in variants):
                    continue
                try:
                    text = data.decode() if is_text(file) else None
                except UnicodeDecodeError:
                    text = None
                if text is None:
                    return f'binary output {file.relative_to(work)} names the scratch directory'
                for variant in variants:
                    for match in re.finditer(re.escape(variant) + r'/([^/"\\\s]+)', text):
                        pending.append(match.group(1))
        temporary = self.directory / f'.tmp-{uuid.uuid4().hex}'
        temporary.mkdir()
        try:
            relocated, size = [], 0
            for relative in sorted(chosen):
                source, target = work / relative, temporary / 'files' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target, symlinks=True)
                else:
                    shutil.copy2(source, target)
                for file in [target] if target.is_file() else sorted(p for p in target.rglob('*') if p.is_file()):
                    size += file.stat().st_size
                    if not is_text(file):
                        continue
                    data = file.read_bytes()
                    if any(v.encode() in data for v in variants):
                        text = data.decode()
                        for variant in variants:
                            text = text.replace(variant, PLACEHOLDER)
                        file.write_text(text)
                        relocated.append(file.relative_to(temporary / 'files').as_posix())
            (temporary / 'log.txt').write_text(log_text)
            meta = {'format': FORMAT, 'key': key, 'outputs': sorted(chosen), 'relocated': sorted(relocated),
                    'seconds': round(seconds, 1), 'bytes': size, 'stored': int(time.time()), 'step': description}
            (temporary / 'meta.json').write_text(json.dumps(meta, indent=1) + '\n')
            final = self.entry(key)
            final.parent.mkdir(parents=True, exist_ok=True)
            try:
                os.rename(temporary, final)
            except OSError:
                pass  # another run stored the same key first
            self.stored += 1
            return None
        finally:
            shutil.rmtree(temporary, ignore_errors=True)

    def prune(self):
        """Drops least recently used entries until the cache fits its limit; an entry used in the
        last hour stays (another run may be restoring it)."""
        entries = []
        for meta in self.steps.glob('*/*/meta.json'):
            try:
                entries.append((meta.stat().st_mtime, json.loads(meta.read_text()).get('bytes', 0), meta.parent))
            except (OSError, ValueError):
                continue
        total = sum(size for _, size, _ in entries)
        removed = 0
        for used, size, path in sorted(entries):
            if total <= self.limit or time.time() - used < 3600:
                break
            # Out of the way in one rename, so a reader sees a whole entry or none.
            doomed = self.directory / f'.tmp-{uuid.uuid4().hex}'
            try:
                os.rename(path, doomed)
            except OSError:
                continue
            shutil.rmtree(doomed, ignore_errors=True)
            total -= size
            removed += 1
        for stale in self.directory.glob('.tmp-*'):
            if time.time() - stale.stat().st_mtime > 6 * 3600:
                shutil.rmtree(stale, ignore_errors=True)
        return total, removed


def jdk_identity(java):
    result = subprocess.run([java, '-XshowSettings:properties', '-version'], capture_output=True, text=True)
    lines = [line.strip() for line in (result.stdout + result.stderr).splitlines()
             if line.strip().startswith(('java.vm.name', 'java.vm.version', 'java.runtime.version', 'java.vendor ',
                                         'os.arch', 'os.name'))]
    version = subprocess.run([java, '-version'], capture_output=True, text=True)
    return '\n'.join(lines + [version.stderr.strip()])
