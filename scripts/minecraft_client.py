#!/usr/bin/env python3
"""Run the dedicated pinned vanilla test client directly into local ValiMC; Ctrl-C stops it."""
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

from pinned import PROTOCOL, VERSION

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALLED = pathlib.Path.home() / "Library/Application Support/minecraft"
TARGET = "127.0.0.1:25565"
PLAYER = "ValiMCTest"
FEATURES = {"has_quick_plays_support": True,
            "is_quick_play_multiplayer": True}


def main_checkout(root):
    """The checkout holding root's Git directory: root itself, or a worktree's main checkout."""
    common = subprocess.run(["git", "-C", str(root), "rev-parse", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return (root / common).resolve().parent


def input_socket(root):
    """The checkout's bridge socket, in the per-user temp directory so that sun_path
    (104 bytes) fits from any worktree; scripts/minecraft_input.py connects to it."""
    temporary = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"],
                               capture_output=True, text=True, check=True).stdout.strip()
    digest = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    return pathlib.Path(temporary) / f"valimc-input-{digest}.sock"


def allowed(entry):
    result = not entry.get("rules")
    for rule in entry.get("rules", []):
        system = rule.get("os", {})
        if (system.get("name", "osx") == "osx"
                and re.fullmatch(system.get("arch", ".*"), "aarch64")
                and all(FEATURES.get(k, False) == v for k, v in rule.get("features", {}).items())):
            result = rule["action"] == "allow"
    return result


def command(run, build, bridge):
    app = build / "Minecraft Client.app/Contents/MacOS/java"
    sdl = build / "sdl-mouse-build/libSDL3.dylib"
    metadata = INSTALLED / "versions" / VERSION / (VERSION + ".json")
    jar = metadata.with_suffix(".jar")
    data = json.loads(metadata.read_text())
    if not app.is_file() or not sdl.is_file() or b"ValiMC internal-pointer backend" not in sdl.read_bytes():
        raise RuntimeError(f"Build the dedicated SDL wrapper in {build.parent} with "
                           "scripts/prepare_minecraft_client.py first")
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
        "version_type": "release",
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
    arguments = [str(app), "-Xmx2G", "-Dlog4j.configurationFile=" + str(logging)]
    arguments += expand(data["arguments"]["jvm"]) + [data["mainClass"]]
    arguments += expand(data["arguments"]["game"])
    details = {"minecraft": VERSION, "protocol": PROTOCOL, "target": TARGET,
               "player": PLAYER, "uuid": str(offline_uuid), "game_directory": values["game_directory"],
               "input_socket": str(bridge),
               "fingerprints": {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [metadata, jar, app, sdl]}}
    return arguments, details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=pathlib.Path,
                        help="Fresh run directory under .local/client-tests/")
    parser.add_argument("--no-activate", action="store_true",
                        help="Open the window without taking focus from the user's app")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("The dedicated test client requires macOS")
    run = args.evidence.resolve()
    if not run.is_relative_to(ROOT / ".local/client-tests"):
        raise SystemExit("Client run evidence must stay under .local/client-tests/")
    # Worktrees launch the main checkout's wrapper: one bundle carries the app ID,
    # and its lock keeps one client running across checkouts.
    build = main_checkout(ROOT) / ".local"
    bridge = input_socket(ROOT)
    arguments, details = command(run, build, bridge)
    details["activates_window"] = not args.no_activate
    with (build / "minecraft-test-client.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another dedicated test client is running; stop it first") from None
        run.mkdir(parents=True, exist_ok=False)
        (run / "game").mkdir()
        for name in ["java", "jna", "lwjgl", "netty"]:
            (run / "natives" / name).mkdir(parents=True)
        (run / "game/options.txt").write_text(
            "fullscreen:false\nonboardAccessibility:false\nskipMultiplayerWarning:true\ntutorialStep:none\n"
            "pauseOnLostFocus:false\nrenderDistance:4\nsimulationDistance:5\nmaxFps:60\nguiScale:0\n"
            "soundCategory_master:0.0\n")

        def stop(_signum, _frame):
            raise KeyboardInterrupt

        signal.signal(signal.SIGTERM, stop)
        with (run / "console.log").open("w") as log:
            # The patched SDL serves scripts/minecraft_input.py here; computer-use input is unchanged.
            environment = {**os.environ, "VALIMC_INPUT_SOCKET": str(bridge)}
            if args.no_activate:
                environment |= {"SDL_MAC_BACKGROUND_APP": "1", "SDL_WINDOW_ACTIVATE_WHEN_SHOWN": "0",
                                "SDL_WINDOW_ACTIVATE_WHEN_RAISED": "0"}
            process = subprocess.Popen(arguments, cwd=run / "game", stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                       env=environment)
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
                if bridge.is_socket():
                    bridge.unlink()
                details["exit_code"] = process.returncode
                (run / "client.json").write_text(json.dumps(details, indent=2) + "\n")
                print(f"Test client stopped (exit {process.returncode})", flush=True)
            return 0 if interrupted else process.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
