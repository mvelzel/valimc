#!/usr/bin/env python3
"""Reject private reference material in the tracked/staged public tree and candidates."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRIVATE = (".local/", "_build/", "deps/", "world/", "logs/", "bench/results/",
           "research/sources/", "research/vanilla-bundle/", "research/generated/",
           "research/java-tools/", "research/decompiled/", "research/disassembly/",
           "research/tools/", "research/vanilla/", "research/logs/")
BINARIES = {".jar", ".class", ".mca", ".mcr", ".etf", ".pose", ".items", ".dylib"}


def violation(name, contents=None):
    if name.startswith(PRIVATE):
        return "private reference/runtime/test path"
    if pathlib.PurePosixPath(name).suffix.lower() in BINARIES:
        return "packaged code or world binary"
    if contents is not None and re.search(rb"(?m)^\s*package\s+net\.minecraft(?:\.|\s*;)", contents):
        return "Mojang implementation source package"
    return None


def audit():
    tracked = subprocess.check_output(["git", "ls-files", "--cached", "-z"], cwd=ROOT)
    candidates = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    indexed = set(tracked.decode().split("\0")) - {""}
    names = sorted(indexed | (set(candidates.decode().split("\0")) - {""}))
    failures = []
    for name in names:
        contents = None
        if name.endswith(".java"):
            # Inspect the index version too, so a sanitized working copy cannot hide a staged source.
            if name in indexed:
                contents = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
            else:
                contents = (ROOT / name).read_bytes()
        reason = violation(name, contents)
        if reason:
            failures.append(f"{name}: {reason}")
    if failures:
        raise SystemExit("PUBLICATION AUDIT FAILED\n" + "\n".join(failures))
    print(f"PASS: {len(names)} tracked/staged/candidate paths contain no prohibited reference artifacts")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        assert violation("research/decompiled/Example.java")
        assert violation(".local/client-tests/VMC-001/shot.png")
        assert violation("server.jar")
        assert violation("copied/player.pose")
        assert violation("copied/r.0.0.items")
        assert violation("libSDL3.dylib")
        assert violation("copied/Example.java", b"package net.minecraft.world;\n")
        assert violation("scripts/Oracle.java", b"import net.minecraft.SharedConstants;\n") is None
        assert violation("priv/protocol/packets.json") is None
        print("PASS: publication guard rejects private paths, binaries and copied Minecraft packages")
    audit()
