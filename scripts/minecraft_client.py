#!/usr/bin/env python3
"""Run the dedicated vanilla 26.3 test client directly into local ValiMC; Ctrl-C stops it."""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALLED = pathlib.Path.home() / "Library/Application Support/minecraft"
APP = ROOT / ".local/Minecraft Client.app/Contents/MacOS/java"
SDL = ROOT / ".local/sdl-mouse-build/libSDL3.dylib"
VERSION = "26.3"
TARGET = "127.0.0.1:25565"
PLAYER = "ValiMCTest"
FEATURES = {"has_custom_resolution": True, "has_quick_plays_support": True,
            "is_quick_play_multiplayer": True}


def allowed(entry):
    result = not entry.get("rules")
    for rule in entry.get("rules", []):
        system = rule.get("os", {})
        if (system.get("name", "osx") == "osx"
                and re.fullmatch(system.get("arch", ".*"), "aarch64")
                and all(FEATURES.get(k, False) == v for k, v in rule.get("features", {}).items())):
            result = rule["action"] == "allow"
    return result


def command(run):
    metadata = INSTALLED / "versions" / VERSION / (VERSION + ".json")
    jar = metadata.with_suffix(".jar")
    data = json.loads(metadata.read_text())
    if not APP.is_file() or not SDL.is_file() or b"ValiMC internal-pointer backend" not in SDL.read_bytes():
        raise RuntimeError("Build the dedicated SDL wrapper with scripts/prepare_minecraft_client.py first")
    if hashlib.sha1(jar.read_bytes()).hexdigest() != data["downloads"]["client"]["sha1"]:
        raise RuntimeError("Installed Minecraft client does not match its version metadata")
    libraries = [INSTALLED / "libraries" / lib["downloads"]["artifact"]["path"]
                 for lib in data["libraries"] if allowed(lib)]
    for path in libraries:
        if not path.is_file():
            raise RuntimeError("Missing installed client library: " + str(path))
    offline_uuid = uuid.UUID(bytes=hashlib.md5(("OfflinePlayer:" + PLAYER).encode()).digest(), version=3)
    values = {
        "auth_player_name": PLAYER, "version_name": VERSION,
        "game_directory": str(run / "game"), "assets_root": str(INSTALLED / "assets"),
        "assets_index_name": data["assetIndex"]["id"], "auth_uuid": offline_uuid.hex,
        "auth_access_token": "0", "clientid": str(uuid.UUID(int=0)), "auth_xuid": "0",
        "version_type": "release", "resolution_width": "1280", "resolution_height": "720",
        "quickPlayPath": str(run / "quickplay.json"), "quickPlayMultiplayer": TARGET,
        "natives_directory": str(run / "natives"), "launcher_name": "ValiMC-test",
        "launcher_version": "1", "classpath": os.pathsep.join(map(str, libraries + [jar])),
    }

    def expand(entries):
        result = []
        for entry in entries:
            if isinstance(entry, dict):
                if not allowed(entry):
                    continue
                entry = entry["value"]
            for value in entry if isinstance(entry, list) else [entry]:
                result.append(re.sub(r"\$\{([^}]+)\}", lambda m: values[m[1]], value))
        return result

    logging = INSTALLED / "assets/log_configs" / data["logging"]["client"]["file"]["id"]
    if not logging.is_file():
        raise RuntimeError("Missing installed client logging configuration")
    arguments = [str(APP), "-Xmx2G", "-Dlog4j.configurationFile=" + str(logging)]
    arguments += expand(data["arguments"]["jvm"]) + [data["mainClass"]]
    arguments += expand(data["arguments"]["game"])
    details = {"minecraft": VERSION, "protocol": 777, "target": TARGET,
               "player": PLAYER, "uuid": str(offline_uuid), "game_directory": values["game_directory"],
               "fingerprints": {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [metadata, jar, APP, SDL]}}
    return arguments, details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=pathlib.Path,
                        help="Fresh run directory under .local/client-tests/")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("The dedicated test client requires macOS")
    run = args.evidence.resolve()
    if not run.is_relative_to(ROOT / ".local/client-tests"):
        raise SystemExit("Client run evidence must stay under .local/client-tests/")
    with (ROOT / ".local/minecraft-test-client.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        arguments, details = command(run)
        run.mkdir(parents=True, exist_ok=False)
        (run / "game").mkdir()
        for name in ["java", "jna", "lwjgl", "netty"]:
            (run / "natives" / name).mkdir(parents=True)
        (run / "game/options.txt").write_text(
            "onboardAccessibility:false\nskipMultiplayerWarning:true\ntutorialStep:none\n"
            "pauseOnLostFocus:false\nrenderDistance:4\nsimulationDistance:5\nmaxFps:60\nguiScale:2\n")

        def stop(_signum, _frame):
            raise KeyboardInterrupt

        signal.signal(signal.SIGTERM, stop)
        with (run / "console.log").open("w") as log:
            process = subprocess.Popen(arguments, cwd=run / "game", stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            details["pid"] = process.pid
            (run / "client.json").write_text(json.dumps(details, indent=2) + "\n")
            print(f"Test client PID {process.pid} → {TARGET}; Ctrl-C this session to stop it", flush=True)
            interrupted = False
            try:
                process.wait()
            except KeyboardInterrupt:
                interrupted = True
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                details["exit_code"] = process.returncode
                (run / "client.json").write_text(json.dumps(details, indent=2) + "\n")
                print(f"Test client stopped (exit {process.returncode})", flush=True)
            return 0 if interrupted else process.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, KeyError) as error:
        sys.exit(str(error))
