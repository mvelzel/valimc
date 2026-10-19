#!/usr/bin/env python3
"""Run development tools against the official Minecraft jar, never the server runtime.

All `scripts/*.java` sources compile together in one javac call (so shared helpers
need no dependency list) and only when a source is newer than the last build.
"""
import os, pathlib, subprocess, sys
from java_runtime import java_home as find_java_home

root = pathlib.Path(__file__).resolve().parent.parent
bundle = root / 'research/vanilla-bundle'
tools = root / 'research/java-tools'
stamp = tools / '.compiled'


def classpath():
    jars = sorted((bundle / 'libraries').rglob('*.jar'))
    jars += [bundle / 'versions/26.3/server-26.3.jar']
    return os.pathsep.join(str(p) for p in jars)


def compile_tools(java_home=None):
    """Compile every oracle once; returns the java executable and runtime classpath."""
    java_home = java_home or find_java_home()
    sources = sorted((root / 'scripts').glob('*.java'))
    tools.mkdir(parents=True, exist_ok=True)
    newest = max(p.stat().st_mtime for p in sources)
    if not stamp.exists() or stamp.stat().st_mtime < newest:
        result = subprocess.run([java_home + '/bin/javac', '-nowarn', '-cp', classpath(), '-d', str(tools),
                                 *map(str, sources)])
        if result.returncode:
            raise SystemExit(result.returncode)
        stamp.touch()
    return java_home + '/bin/java', str(tools) + os.pathsep + classpath()


def command(name, *args):
    java, cp = compile_tools()
    return [java, '-cp', cp, name, *args]


if __name__ == '__main__':
    sys.exit(subprocess.run(command(sys.argv[1], *sys.argv[2:])).returncode)
