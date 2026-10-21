#!/usr/bin/env python3
"""Run every vanilla oracle stage in parallel, then the official-codec TCP oracle.

Usage: check_vanilla.py [--jobs N] [--only NAME ...] [--skip-tcp] [--list] [--audit]

Stages live in `vanilla_stages.py`. Logs go to `.local/vanilla-checks/<stage>.log`.
All failures are collected and reported; the exit status is non-zero if any failed.
"""
import argparse, concurrent.futures as cf, json, os, pathlib, shutil, socket, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import java_tool
from vanilla_stages import HELPERS, STAGES

root = java_tool.root
logs = root / '.local/vanilla-checks'
# A private build compiled once up front: concurrent source edits cannot change a run.
mix_env = dict(os.environ, MIX_BUILD_PATH=str(root / '.local/vanilla-checks/_build'),
               VALIMC_BUILD_EMBEDDED='1')


def audit():
    """Every oracle and checker must be a registered stage step or a declared helper."""
    used = {step[1] for _, steps in STAGES for step in steps if step[0] in ('java', 'check', 'app')}
    missing = [p.stem for p in (root / 'scripts').glob('*.java') if p.stem not in used and p.stem not in HELPERS]
    missing += [p.name for p in (root / 'scripts').glob('check_*.exs') if p.name not in used]
    unknown = [name for name in used if not (root / 'scripts' / name).exists()
               and not (root / 'scripts' / (name + '.java')).exists()]
    for name in sorted(missing):
        print(f'UNREGISTERED: scripts/{name} is not in vanilla_stages.py', file=sys.stderr)
    for name in sorted(unknown):
        print(f'UNKNOWN: vanilla_stages.py references missing {name}', file=sys.stderr)
    return not missing and not unknown


def run_stage(name, steps, java, cp):
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
                    cmd = [java, *java_tool.JVM_FLAGS, '-cp', cp, target, *args]
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
                        return name, False, time.monotonic() - started
                    log.write(f'PASS: {target} matches {args[0]}\n')
                    continue
                else:
                    raise ValueError(kind)
                shown = [target, *args] if kind == 'java' else cmd
                log.write(f'$ {" ".join(shown)}\n')
                log.flush()
                result = subprocess.run(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
                if result.returncode:
                    return name, False, time.monotonic() - started
        return name, True, time.monotonic() - started
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_tcp(java, cp):
    """Plain and encrypted official-codec sessions against isolated servers."""
    ok = True
    with tempfile.TemporaryDirectory(prefix='valimc-oracle-tcp-') as world:
        for mode, encrypted in [('plain', False), ('encrypted', True)]:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            env = dict(mix_env, VALIMC_PORT=str(port), VALIMC_WORLD=str(pathlib.Path(world) / mode),
                       VALIMC_ENCRYPTION=str(encrypted).lower(), VALIMC_ONLINE_MODE='false',
                       VALIMC_GAME_MODE='creative', VALIMC_RESPAWN_RADIUS='0')
            log_path = logs / f'tcp-{mode}-server.log'
            with log_path.open('w') as log:
                server = subprocess.Popen(['mix', 'run', '--no-compile', '--no-deps-check', '--no-halt'], cwd=root, env=env, stdout=log,
                                          stderr=subprocess.STDOUT)
                try:
                    for _ in range(400):
                        if server.poll() is not None or 'listening on' in log_path.read_text():
                            break
                        time.sleep(0.05)
                    if server.poll() is not None or 'listening on' not in log_path.read_text():
                        print(f'FAIL tcp-{mode}: server did not start; see {log_path}', file=sys.stderr)
                        ok = False
                        continue
                    with (logs / f'tcp-{mode}.log').open('w') as client_log:
                        result = subprocess.run([java, '-cp', cp, 'VanillaOracle', str(port), mode], cwd=root,
                                                stdout=client_log, stderr=subprocess.STDOUT)
                    print(f'{"PASS" if result.returncode == 0 else "FAIL"} tcp-{mode}')
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
    parser.add_argument('--only', nargs='*', help='stage names (substring match)')
    parser.add_argument('--skip-tcp', action='store_true')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--audit', action='store_true', help='only check stage registration')
    opts = parser.parse_args()
    if opts.list:
        for name, steps in STAGES:
            print(name, ' '.join(s[1] for s in steps if s[0] != 'same'))
        return 0
    if not audit():
        return 1
    if opts.audit:
        print(f'PASS: {len(STAGES)} stages register every oracle and checker')
        return 0
    stages = [(n, s) for n, s in STAGES if not opts.only or any(o in n for o in opts.only)]
    logs.mkdir(parents=True, exist_ok=True)
    subprocess.run(['mix', 'compile'], cwd=root, env=mix_env, check=True)
    java, cp = java_tool.compile_tools()
    started = time.monotonic()
    failed = []
    with cf.ThreadPoolExecutor(opts.jobs) as pool:
        for future in cf.as_completed(pool.submit(run_stage, n, s, java, cp) for n, s in stages):
            name, ok, seconds = future.result()
            print(f'{"PASS" if ok else "FAIL"} {name} ({seconds:.1f}s)', flush=True)
            if not ok:
                failed.append(name)
    tcp_ok = opts.skip_tcp or opts.only or run_tcp(java, cp)
    print(f'{len(stages) - len(failed)}/{len(stages)} stages passed in {time.monotonic() - started:.0f}s; '
          f'logs in {logs.relative_to(root)}')
    for name in sorted(failed):
        print(f'  FAILED {name}: {logs.relative_to(root)}/{name}.log', file=sys.stderr)
    return 1 if failed or not tcp_ok else 0


if __name__ == '__main__':
    sys.exit(main())
