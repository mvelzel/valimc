#!/usr/bin/env python3
"""Apply an opt-in remote-pointer adapter to the pinned, private SDL checkout.

This changes only the dedicated GUI test input backend, never server behavior or
Minecraft classes. SDL's upstream source and license stay in the ignored checkout.
"""
import argparse
import pathlib
import subprocess

REVISION = "ab5541ec5d4377dcc20a701897437f07ba71566f"
ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=pathlib.Path, default=ROOT / "research/tools/SDL")
args = parser.parse_args()
source = args.source.resolve()

def git(*arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments])

if git("rev-parse", "HEAD").decode().strip() != REVISION:
    raise SystemExit("Preserving SDL checkout: revision does not match the pinned experiment")

changes = [
    ("src/video/cocoa/SDL_cocoamouse.m",
     "            Cocoa_ReconcileButtonState(event);\n",
     '''            // Remote events supply their own ordered button transitions via the window listener.
            if (!SDL_GetHintBoolean("VALIMC_CUA_EVENT_POSITION", false))
'''),
    ("src/video/cocoa/SDL_cocoawindow.m",
     "    // GCMouse handles button events directly, skip NSEvent path to avoid duplicates\n",
     '''    // Move before the button-down transition; otherwise a click can become a drag.
    if (SDL_GetHintBoolean("VALIMC_CUA_EVENT_POSITION", false) && down && !mouse->relative_mode) {
        const NSPoint point = [theEvent locationInWindow];
        SDL_SendMouseMotion(Cocoa_GetEventTimestamp([theEvent timestamp]), window,
                            SDL_DEFAULT_MOUSE_ID, false, point.x, window->h - point.y);
    }

'''),
    ("src/video/cocoa/SDL_cocoamouse.m",
     "    deltaX = [event deltaX];\n    deltaY = [event deltaY];\n",
     '''    // Local remote-input experiment: zero-delta synthetic events carry absolute positions.
    if (SDL_GetHintBoolean("VALIMC_CUA_EVENT_POSITION", false) && mouse->focus && [event window]) {
        static NSPoint previous;
        static SDL_Window *previousWindow;
        const NSPoint point = [event locationInWindow];
        if (seenWarp || previousWindow != mouse->focus) {
            previous = NSMakePoint(mouse->focus->w / 2.0, mouse->focus->h / 2.0);
            previousWindow = mouse->focus;
        }
        deltaX = point.x - previous.x;
        deltaY = previous.y - point.y;
        previous = point;
        SDL_SendMouseMotion(Cocoa_GetEventTimestamp([event timestamp]), mouse->focus,
                            mouseID, true, deltaX, deltaY);
        return;
    }

'''),
    ("src/video/cocoa/SDL_cocoawindow.m",
     "    // On macOS 26 if you move away from a space and then back, mouse motion events will have incorrect\n",
     '''    // Remote absolute motion must not be overwritten by the physical desktop pointer.
    if (SDL_GetHintBoolean("VALIMC_CUA_EVENT_POSITION", false)) {
        SDL_SendMouseMotion(Cocoa_GetEventTimestamp([theEvent timestamp]), window,
                            mouseID, false, x, y);
        return;
    }

'''),
]

# Preflight every target before writing, preserving unrelated local edits.
pending = {}
legacy = {}
for index, (relative, anchor, insertion) in enumerate(changes):
    original = git("show", f"HEAD:{relative}").decode()
    if original.count(anchor) != 1:
        raise SystemExit(f"Expected one insertion point: {relative}")
    patched = pending.get(source / relative, original).replace(anchor, insertion + anchor)
    target = source / relative
    pending[target] = patched
    if index < 3:
        legacy[target] = patched

for target, patched in pending.items():
    original = git("show", f"HEAD:{target.relative_to(source)}").decode()
    if target.read_text() not in (original, patched, legacy.get(target, original)):
        raise SystemExit(f"Preserving unexpected local edits: {target.relative_to(source)}")

for target, patched in pending.items():
    target.write_text(patched)
print("Prepared opt-in VALIMC_CUA_EVENT_POSITION adapter; rebuild isolated SDL before launching")
