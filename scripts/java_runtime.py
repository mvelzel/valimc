"""Locate Java 25+ for optional protocol research/validation tools."""
import os, pathlib, re, shutil, subprocess

def java_home():
    requested = os.environ.get('VALIMC_JAVA_HOME')
    candidates = [requested] if requested else [
        os.environ.get('JAVA_HOME'),
        str(pathlib.Path(__file__).resolve().parent.parent / '.local/toolchains/jdk/Contents/Home'),
        str(pathlib.Path(shutil.which('javac') or '/usr/bin/javac').resolve().parent.parent)]
    for candidate in candidates:
        if not candidate:
            continue
        executable = pathlib.Path(candidate) / 'bin/java'
        if not executable.exists():
            continue
        result = subprocess.run([str(executable),'-version'],capture_output=True,text=True)
        match = re.search(r'version "(\d+)',result.stdout+result.stderr)
        if match and int(match[1]) >= 25:
            return str(pathlib.Path(candidate))
    raise SystemExit('Protocol development tools require Java 25+. Set VALIMC_JAVA_HOME to a suitable JDK; the Elixir server itself needs no Java.')
