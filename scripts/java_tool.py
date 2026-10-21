#!/usr/bin/env python3
"""Run development tools against the official Minecraft jar, never the server runtime.

All `scripts/*.java` sources compile together in one javac call (so shared helpers
need no dependency list) into a class directory named by the hash of every source,
the pinned jar and libraries and the JDK: `.local/oracle-cache/classes/` in the main
checkout, shared by every worktree. Directories are complete before they are renamed
into place and never change after, so a running stage cannot see another build's
classes; the twelve most recently used are kept.
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, uuid
from heavy import main_checkout
from java_runtime import java_home as find_java_home
from pinned import VERSION

root = pathlib.Path(__file__).resolve().parent.parent
shared = main_checkout() / '.local/oracle-cache'
# A worktree without its own extracted bundle uses the main checkout's (`prepare_vanilla.py`).
bundle = next((path for path in (root / 'research/vanilla-bundle', main_checkout() / 'research/vanilla-bundle')
               if (path / f'versions/{VERSION}/server-{VERSION}.jar').exists()), root / 'research/vanilla-bundle')
# `Math.sin` and `Math.cos` as `StrictMath` gives them (fdlibm), not as this JVM's
# intrinsics do, which differ in the last place for some inputs (VMC-025f5).
JVM_FLAGS = ['-XX:+UnlockDiagnosticVMOptions', '-XX:DisableIntrinsic=_dsin,_dcos']
KEEP_BUILDS = 12


def jars():
    return sorted((bundle / 'libraries').rglob('*.jar')) + [bundle / f'versions/{VERSION}/server-{VERSION}.jar']


def classpath():
    return os.pathsep.join(str(p) for p in jars())


def digests(paths):
    """sha256 of each file, remembered by path, size and mtime across runs."""
    import oracle_cache
    memo_path = shared / 'file-digests.json'
    try:
        memo = json.loads(memo_path.read_text())
    except (OSError, ValueError):
        memo = {}
    before = len(memo)
    out = [oracle_cache.file_digest(path, memo) for path in paths]
    if len(memo) != before:
        shared.mkdir(parents=True, exist_ok=True)
        temporary = memo_path.with_name(f'.file-digests-{uuid.uuid4().hex}.json')
        temporary.write_text(json.dumps(memo))
        os.replace(temporary, memo_path)
    return out


def runtime(java_home=None):
    """Digest of what every oracle run depends on outside `scripts/`: jars, JDK, flags."""
    import oracle_cache
    java_home = java_home or find_java_home()
    paths = jars()
    parts = [f'{p.relative_to(bundle).as_posix()} {d}' for p, d in zip(paths, digests(paths))]
    parts += [oracle_cache.jdk_identity(java_home + '/bin/java'), ' '.join(JVM_FLAGS)]
    return hashlib.sha256('\n'.join(parts).encode()).hexdigest()


def link_jar():
    """A worktree's pinned server jar is the main checkout's (oracles read it by relative path)."""
    local, main = root / f'research/server-{VERSION}.jar', main_checkout() / f'research/server-{VERSION}.jar'
    if not local.exists() and main.exists():
        try:
            local.symlink_to(main)
        except FileExistsError:
            pass


def compile_tools(java_home=None, identity=None):
    """Compile every oracle once per source tree; returns the java executable and classpath."""
    java_home = java_home or find_java_home()
    link_jar()
    identity = identity or runtime(java_home)
    sources = sorted((root / 'scripts').glob('*.java'))
    tree = hashlib.sha256(identity.encode())
    for path in sources:
        tree.update(path.name.encode() + b'\0' + hashlib.sha256(path.read_bytes()).digest())
    builds = shared / 'classes'
    classes = builds / tree.hexdigest()[:24]
    if not (classes / '.complete').exists():
        temporary = builds / f'.tmp-{uuid.uuid4().hex}'
        temporary.mkdir(parents=True)
        result = subprocess.run([java_home + '/bin/javac', '-nowarn', '-cp', classpath(), '-d', str(temporary),
                                 *map(str, sources)])
        if result.returncode:
            shutil.rmtree(temporary, ignore_errors=True)
            raise SystemExit(result.returncode)
        (temporary / '.complete').touch()
        try:
            os.rename(temporary, classes)
        except OSError:
            shutil.rmtree(temporary, ignore_errors=True)  # another checkout built the same tree
    os.utime(classes / '.complete')
    for old in sorted(builds.glob('*/.complete'), key=lambda p: p.stat().st_mtime, reverse=True)[KEEP_BUILDS:]:
        shutil.rmtree(old.parent, ignore_errors=True)
    return java_home + '/bin/java', str(classes) + os.pathsep + classpath()


def command(name, *args):
    java, cp = compile_tools()
    return [java, *JVM_FLAGS, '-cp', cp, name, *args]


if __name__ == '__main__':
    sys.exit(subprocess.run(command(sys.argv[1], *sys.argv[2:])).returncode)
