#!/usr/bin/env python3
"""Run a heavy command in one of a few machine-wide slots, at low priority.

    python3 scripts/heavy.py mix test
    python3 scripts/heavy.py python3 scripts/check_vanilla.py
    python3 scripts/heavy.py --status

Heavy means the full test suite, all vanilla stages, a release build or a
benchmark: anything that keeps most cores busy for minutes. Every checkout and
worktree shares the slots in the main checkout's `.local/heavy/`, so sessions
queue instead of overloading the host. `VALIMC_HEAVY_SLOTS` sets how many
(default 2). A slot is an flock on its file and frees itself when its holder
exits. Commands started under a slot (`VALIMC_HEAVY_HELD`) take no second one.
"""
import json, os, pathlib, signal, subprocess, sys, time
import fcntl

root = pathlib.Path(__file__).resolve().parent.parent
NICENESS = 10


def main_checkout():
    """The checkout holding this one's Git directory: itself, or a worktree's main checkout."""
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--git-common-dir'],
                            capture_output=True, text=True, check=True).stdout.strip()
    return (root / common).resolve().parent


def slot_paths():
    directory = main_checkout() / '.local/heavy'
    directory.mkdir(parents=True, exist_ok=True)
    count = max(1, int(os.environ.get('VALIMC_HEAVY_SLOTS', '2')))
    return [directory / f'slot-{index}.lock' for index in range(count)]


def describe(path):
    try:
        holder = json.loads(path.read_text())
    except (OSError, ValueError):
        return 'unknown holder'
    minutes = (time.time() - holder['started']) / 60
    return f"pid {holder['pid']}, {minutes:.0f} min, {holder['cwd']}: {holder['command']}"


def try_slot(path):
    handle = path.open('a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def acquire(command):
    """Blocks until a slot is free; returns its open, locked file."""
    paths, waited = slot_paths(), False
    while True:
        for path in paths:
            handle = try_slot(path)
            if handle:
                handle.seek(0)
                handle.truncate()
                handle.write(json.dumps({'pid': os.getpid(), 'started': time.time(),
                                         'cwd': os.getcwd(), 'command': ' '.join(command)}))
                handle.flush()
                if waited:
                    print('heavy: got a slot', file=sys.stderr, flush=True)
                return handle
        if not waited:
            print(f'heavy: all {len(paths)} slots are busy; waiting', file=sys.stderr)
            for path in paths:
                print(f'  {describe(path)}', file=sys.stderr)
            sys.stderr.flush()
            waited = True
        time.sleep(2)


def status():
    for index, path in enumerate(slot_paths()):
        handle = try_slot(path)
        if handle:
            handle.close()
            print(f'slot {index}: free')
        else:
            print(f'slot {index}: {describe(path)}')


def run(command):
    if os.environ.get('VALIMC_HEAVY_HELD'):
        os.execvp(command[0], command)
    slot = acquire(command)
    process = subprocess.Popen(command, env=dict(os.environ, VALIMC_HEAVY_HELD='1'),
                               preexec_fn=lambda: os.nice(NICENESS))
    # A terminal's Ctrl-C reaches the command's process group directly; a TERM or
    # HUP sent to this wrapper alone is passed on.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda sig, _frame: process.send_signal(sig))
    code = process.wait()
    slot.close()
    return 128 - code if code < 0 else code


if __name__ == '__main__':
    arguments = sys.argv[1:]
    if arguments == ['--status']:
        status()
    elif not arguments or arguments[0].startswith('-'):
        sys.exit(__doc__)
    else:
        sys.exit(run(arguments))
