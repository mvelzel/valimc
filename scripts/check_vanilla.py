#!/usr/bin/env python3
"""Run vanilla oracle stages in parallel, longest first, and the official-codec TCP stage.

Usage: check_vanilla.py [--jobs N] [--only NAME[,NAME] ...] [--skip-tcp] [--list] [--audit]

`--only` takes exact stage names (comma-separated or repeated); a name with `*`, `?`
or `[` is a glob. A name that matches nothing is an error. `tcp` names the TCP stage
(plain and encrypted sessions against two ValiMC servers); it runs unless
`--skip-tcp` or an `--only` that leaves it out.

Stages live in `vanilla_stages.py`. Logs go to `.local/vanilla-checks/<stage>.log`.
Stage durations are kept in the main checkout's `.local/oracle-cache/timings.json`
(shared by every worktree) and order the next run, longest first. A run of more than
a few stages takes a heavy-job slot (`scripts/heavy.py`) unless it already holds one.
All failures are collected and reported; the exit status is non-zero if any failed.
"""
import argparse, concurrent.futures as cf, contextlib, difflib, fcntl, fnmatch, json, os, pathlib, shutil, socket, \
    subprocess, sys, tempfile, threading, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import heavy, java_tool
from vanilla_stages import ESTIMATES, HELPERS, STAGES, THREADED

root = java_tool.root
logs = root / '.local/vanilla-checks'
TCP = 'tcp'
# Runs of up to this many stages are small enough to skip the heavy-job slot.
HANDFUL = 6
# A private build compiled once up front: concurrent source edits cannot change a run.
mix_env = dict(os.environ, MIX_BUILD_PATH=str(root / '.local/vanilla-checks/_build'),
               VALIMC_BUILD_EMBEDDED='1')
# One all-core oracle at a time, sized to the cores the other jobs leave free.
all_core = threading.Lock()


def shared_dir():
    """The main checkout's `.local/oracle-cache`, shared by every worktree."""
    path = heavy.main_checkout() / '.local/oracle-cache'
    path.mkdir(parents=True, exist_ok=True)
    return path


def audit():
    """Every oracle and checker must be a registered stage step or a declared helper."""
    used = {step[1] for _, steps in STAGES for step in steps if step[0] in ('java', 'check', 'app')}
    missing = [p.stem for p in (root / 'scripts').glob('*.java') if p.stem not in used and p.stem not in HELPERS]
    missing += [p.name for p in (root / 'scripts').glob('check_*.exs') if p.name not in used]
    unknown = [name for name in used if not (root / 'scripts' / name).exists()
               and not (root / 'scripts' / (name + '.java')).exists()]
    names = [name for name, _ in STAGES]
    duplicate = sorted({name for name in names if names.count(name) > 1 or name == TCP})
    for name in sorted(missing):
        print(f'UNREGISTERED: scripts/{name} is not in vanilla_stages.py', file=sys.stderr)
    for name in sorted(unknown):
        print(f'UNKNOWN: vanilla_stages.py references missing {name}', file=sys.stderr)
    for name in duplicate:
        print(f'DUPLICATE: stage name {name} is used twice or reserved', file=sys.stderr)
    return not missing and not unknown and not duplicate


def select(patterns, skip_tcp):
    """Stage names for `--only` patterns (exact, or globs); exits when a pattern matches nothing."""
    names = [name for name, _ in STAGES] + [TCP]
    if not patterns:
        return [name for name in names if name != TCP or not skip_tcp]
    chosen, unmatched = set(), []
    for pattern in (p.strip() for value in patterns for p in value.split(',')):
        if not pattern:
            continue
        found = fnmatch.filter(names, pattern) if any(c in pattern for c in '*?[') else \
            [pattern] if pattern in names else []
        if not found:
            close = difflib.get_close_matches(pattern, names, n=3, cutoff=0.6)
            unmatched.append(pattern + (f' (did you mean {", ".join(close)}?)' if close else ''))
        chosen.update(found)
    if unmatched:
        sys.exit('check_vanilla: no stage matches ' + '; '.join(unmatched))
    return [name for name in names if name in chosen and not (name == TCP and skip_tcp)]


class Timings:
    """Per-stage wall seconds of the last run, shared by every worktree."""

    def __init__(self):
        self.path = shared_dir() / 'timings.json'
        try:
            self.known = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.known = {}
        self.measured = {}

    def estimate(self, name):
        entry = self.known.get(name)
        return entry['seconds'] if entry else ESTIMATES.get(name, 15)

    def record(self, name, seconds):
        self.measured[name] = {'seconds': round(seconds, 1), 'at': int(time.time())}

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
            known.update(self.measured)
            temporary = self.path.with_name(f'.timings-{os.getpid()}.json')
            temporary.write_text(json.dumps(known, indent=1, sort_keys=True) + '\n')
            os.replace(temporary, self.path)


def java_command(java, cp, target, args, jobs):
    if target not in THREADED:
        return [java, *java_tool.JVM_FLAGS, '-cp', cp, target, *args]
    threads = max(2, (os.cpu_count() or 2) - jobs + 1)
    return [java, *java_tool.JVM_FLAGS, f'-XX:ActiveProcessorCount={threads}', '-cp', cp, target, *args]


def run_stage(name, steps, java, cp, jobs):
    work = pathlib.Path(tempfile.mkdtemp(prefix=f'valimc-oracle-{name}-'))
    log_path = logs / f'{name}.log'
    resolve = lambda arg: str(work / arg[1:]) if arg.startswith('@') else arg
    started = time.monotonic()
    try:
        with log_path.open('w') as log:
            for kind, target, *args in steps:
                args = [resolve(a) for a in args]
                env = mix_env
                if kind == 'java':
                    cmd = java_command(java, cp, target, args, jobs)
                elif kind == 'check':
                    cmd = ['mix', 'run', '--no-compile', '--no-deps-check', '--no-start', f'scripts/{target}', *args]
                elif kind == 'app':
                    cmd = ['mix', 'run', '--no-compile', '--no-deps-check', f'scripts/{target}', *args]
                    env = dict(mix_env, VALIMC_PORT='0', VALIMC_WORLD=str(work / 'world'))
                elif kind == 'same':
                    generated, committed = json.loads(pathlib.Path(resolve(target)).read_text()), \
                        json.loads((root / args[0]).read_text())
                    if generated != committed:
                        log.write(f'FAIL: generated {target} differs from committed {args[0]}\n')
                        return False
                    log.write(f'PASS: {target} matches {args[0]}\n')
                    continue
                else:
                    raise ValueError(kind)
                shown = [target, *args] if kind == 'java' else cmd
                log.write(f'$ {" ".join(shown)}\n')
                log.flush()
                with all_core if kind == 'java' and target in THREADED else contextlib.nullcontext():
                    result = subprocess.run(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
                if result.returncode:
                    return False
        return True
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_tcp(java, cp):
    """Plain and encrypted official-codec sessions against isolated servers."""
    ok = True
    with tempfile.TemporaryDirectory(prefix='valimc-oracle-tcp-') as world, (logs / f'{TCP}.log').open('w') as summary:
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
                    for _ in range(400):
                        if server.poll() is not None or 'listening on' in log_path.read_text():
                            break
                        time.sleep(0.05)
                    if server.poll() is not None or 'listening on' not in log_path.read_text():
                        summary.write(f'FAIL tcp-{mode}: server did not start; see {log_path.name}\n')
                        ok = False
                        continue
                    with (logs / f'tcp-{mode}.log').open('w') as client_log:
                        result = subprocess.run([java, *java_tool.JVM_FLAGS, '-cp', cp, 'VanillaOracle', str(port), mode],
                                                cwd=root, stdout=client_log, stderr=subprocess.STDOUT)
                    summary.write(f'{"PASS" if result.returncode == 0 else "FAIL"} tcp-{mode}; see tcp-{mode}.log\n')
                    ok = ok and result.returncode == 0
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument('--only', nargs='+', action='extend', metavar='NAME',
                        help='exact stage names, comma-separated or repeated; globs only with * ? [')
    parser.add_argument('--skip-tcp', action='store_true')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--audit', action='store_true', help='only check stage registration')
    opts = parser.parse_args()
    if not audit():
        return 1
    if opts.audit:
        print(f'PASS: {len(STAGES)} stages register every oracle and checker')
        return 0
    timings = Timings()
    if opts.list:
        for name, steps in STAGES:
            print(f'{name} ({timings.estimate(name):.0f}s)', ' '.join(s[1] for s in steps if s[0] != 'same'))
        print(f'{TCP} ({timings.estimate(TCP):.0f}s) VanillaOracle against plain and encrypted servers')
        return 0
    names = select(opts.only, opts.skip_tcp)
    steps_of = dict(STAGES)
    slot = None
    if len(names) > HANDFUL and not os.environ.get('VALIMC_HEAVY_HELD'):
        slot = heavy.acquire(sys.argv)
        os.environ['VALIMC_HEAVY_HELD'] = mix_env['VALIMC_HEAVY_HELD'] = '1'
        os.nice(heavy.NICENESS)
    logs.mkdir(parents=True, exist_ok=True)
    subprocess.run(['mix', 'compile'], cwd=root, env=mix_env, check=True)
    java, cp = java_tool.compile_tools()
    started = time.monotonic()
    failed = []
    order = sorted(names, key=timings.estimate, reverse=True)

    def run(name):
        begun = time.monotonic()
        ok = run_tcp(java, cp) if name == TCP else run_stage(name, steps_of[name], java, cp, opts.jobs)
        return name, ok, time.monotonic() - begun

    with cf.ThreadPoolExecutor(opts.jobs) as pool:
        for future in cf.as_completed([pool.submit(run, name) for name in order]):
            name, ok, seconds = future.result()
            timings.record(name, seconds)
            print(f'{"PASS" if ok else "FAIL"} {name} ({seconds:.1f}s)', flush=True)
            if not ok:
                failed.append(name)
    timings.save()
    print(f'{len(names) - len(failed)}/{len(names)} stages passed in {time.monotonic() - started:.0f}s; '
          f'logs in {logs.relative_to(root)}')
    for name in sorted(failed):
        print(f'  FAILED {name}: {logs.relative_to(root)}/{name}.log', file=sys.stderr)
    if slot:
        slot.close()
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
