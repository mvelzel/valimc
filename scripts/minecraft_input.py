#!/usr/bin/env python3
"""Send background input to the running dedicated test client through its SDL bridge.

Each argument (or each stdin line with `-`) is one command; a call is one batch that
returns after the game consumed it. Coordinates are window-screenshot points with a
top-left origin, title bar included (`state` reports its height). Commands:

  click X Y [left|right|middle] [COUNT]   move X Y              drag X1 Y1 X2 Y2 [BUTTON] [STEPS]
  press|down|up [BUTTON]                   look DX DY [STEPS]    scroll Y (positive = wheel up)
  key NAME | keydown NAME | keyup NAME     type TEXT             wait MS
  release (all held buttons/keys)          state

Key names follow SDL (e, t, Escape, Return, F3, Left Shift, Space, 1) plus aliases
shift, ctrl, alt, cmd, esc and enter. `look` only works while the game captures the
mouse; `move`/`click` coordinates only while a screen shows the pointer.
Example: minecraft_input.py "key t" "wait 200" "type /stats" "key Return"
"""
import socket
import sys

from minecraft_client import ROOT, input_socket


def main():
    commands = sys.argv[1:]
    if not commands or commands[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if commands else 2
    if commands == ["-"]:
        commands = sys.stdin.read().splitlines()
    if any("\n" in command for command in commands):
        raise SystemExit("One command per argument")
    batch = "\n".join(commands).encode() + b"\n"
    path = input_socket(ROOT)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(90)
        try:
            client.connect(str(path))
        except OSError as error:
            raise SystemExit(f"No test client input bridge at {path}: {error}. "
                             "Launch scripts/minecraft_client.py first.")
        client.sendall(batch)
        client.shutdown(socket.SHUT_WR)
        reply = b""
        while chunk := client.recv(4096):
            reply += chunk
    reply = reply.decode(errors="replace").strip()
    print(reply)
    return 0 if reply.startswith("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
