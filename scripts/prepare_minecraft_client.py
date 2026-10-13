#!/usr/bin/env python3
"""Build a local macOS app identity for the installed official Minecraft Java runtime.

Development UI helper only. No game download, account handling, client modifications,
LaunchServices bypass, or official-binary re-signing. Configure its executable in a
separate Minecraft Launcher installation, then use normal computer-use app approval.
"""
import argparse
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--java-home", type=pathlib.Path,
                    help="Installed Minecraft runtime Home directory (defaults to java-runtime-epsilon)")
args = parser.parse_args()
if sys.platform != "darwin":
    raise SystemExit("This app-identity helper is for macOS. Other platforms use their native app/window selector.")
runtime = args.java_home or (pathlib.Path.home() / "Library/Application Support/minecraft/runtime/"
                            "java-runtime-epsilon/mac-os-arm64/java-runtime-epsilon/jre.bundle/Contents/Home")
runtime = runtime.resolve()
if not (runtime / "lib/libjli.dylib").is_file():
    raise SystemExit("Installed Java runtime not found; pass --java-home with its Home directory")
release = dict(re.findall(r'^([A-Z_]+)="([^"]*)"$', (runtime / "release").read_text(), re.M))
version = release["JAVA_VERSION"]
full_version = release.get("JAVA_RUNTIME_VERSION", version)
if int(version.split(".")[0]) < 25:
    raise SystemExit("Minecraft 26.3 requires Java 25+")
quote = lambda value: json.dumps(str(value), ensure_ascii=False)
base = ROOT / ".local"
contents = base / "Minecraft Client.app/Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
for name in ("lib", "conf", "legal", "release"):
    target = contents / name
    if target.is_symlink():
        target.unlink()
    elif target.exists():
        raise SystemExit(f"Preserving unexpected non-symlink: {target}")
    target.symlink_to(runtime / name, target_is_directory=(runtime / name).is_dir())
info = {"CFBundleIdentifier": "local.valimc.minecraft-client", "CFBundleName": "Minecraft Client",
        "CFBundleDisplayName": "Minecraft Client", "CFBundleExecutable": "java",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "NSHighResolutionCapable": True, "LSApplicationCategoryType": "public.app-category.games"}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
source = base / "minecraft-java-launcher.c"
source.write_text(f'''// Original local development launcher; official runtime/classes stay unchanged.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
typedef unsigned char jboolean;
typedef int (*launch_fn)(int, char **, int, const char **, int, const char **,
                        const char *, const char *, const char *, const char *,
                        jboolean, jboolean, jboolean, int);
typedef void (*init_fn)(jboolean, jboolean);
int main(int argc, char **argv) {{
  void *handle = dlopen({quote(runtime / 'lib/libjli.dylib')}, RTLD_NOW | RTLD_GLOBAL);
  if (!handle) {{ fprintf(stderr, "Java launcher library: %s\\n", dlerror()); return 1; }}
  launch_fn launch = (launch_fn)dlsym(handle, "JLI_Launch");
  init_fn init = (init_fn)dlsym(handle, "JLI_InitArgProcessing");
  if (!launch || !init) {{ fprintf(stderr, "Missing OpenJDK launcher entry point\\n"); return 1; }}
  setenv("JAVA_HOME", {quote(runtime)}, 1);
  init(0, 0);
  return launch(argc, argv, 0, NULL, 0, NULL, {quote(full_version)}, {quote(version)},
                "java", "java", 0, 1, 0, 0);
}}
''')
executable = contents / "MacOS/java"
temporary = contents / "MacOS/java.build"
subprocess.run(["clang", "-O2", "-Wall", "-Wextra", str(source), "-o", str(temporary)], check=True)
os.replace(temporary, executable)
subprocess.run([str(executable), "-version"], check=True)
print("Java executable for the separate ValiMC computer-use test installation:")
print(executable)
print("Computer-use app ID: local.valimc.minecraft-client")
