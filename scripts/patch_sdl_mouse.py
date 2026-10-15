#!/usr/bin/env python3
"""Prepare the dedicated Minecraft SDL backend with an internal-only pointer.

Pinned upstream source/license and native build products stay ignored. This
changes input handling only; Minecraft classes and server code stay intact.
"""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "research/tools/SDL"
REVISION = "ab5541ec5d4377dcc20a701897437f07ba71566f"
HEADER = "src/video/cocoa/SDL_cocoacua.h"
CHANGES = [
    ("src/video/cocoa/SDL_cocoamouse.m", "#if 0\n#define DEBUG_COCOAMOUSE",
     '#include "SDL_cocoacua.h"\n\n#if 0\n#define DEBUG_COCOAMOUSE'),
    ("src/video/cocoa/SDL_cocoawindow.m", "#if 0\n#define DEBUG_COCOAWINDOW",
     '#include "SDL_cocoacua.h"\n\n#if 0\n#define DEBUG_COCOAWINDOW'),
    ("src/video/cocoa/SDL_cocoamouse.m", "    mouse->internal = data;\n",
     '    SDL_Log("ValiMC internal-pointer backend");\n    mouse->internal = data;\n'),
    ("src/video/cocoa/SDL_cocoamouse.m", "            Cocoa_ReconcileButtonState(event);\n",
     '            // Button transitions come from window events, not the desktop mouse.\n'),
    ("src/video/cocoa/SDL_cocoawindow.m",
     "    // GCMouse handles button events directly, skip NSEvent path to avoid duplicates\n",
     '''    // Position must precede button-down, or a click can become a drag.
    if (down && !mouse->relative_mode) {
        const NSPoint point = [theEvent locationInWindow];
        SDL_SendMouseMotion(Cocoa_GetEventTimestamp([theEvent timestamp]), window,
                            SDL_DEFAULT_MOUSE_ID, false, point.x, window->h - point.y);
    }

    // GCMouse handles button events directly, skip NSEvent path to avoid duplicates
'''),
    ("src/video/cocoa/SDL_cocoamouse.m", "    deltaX = [event deltaX];\n    deltaY = [event deltaY];\n",
     '''    // Absolute event positions drive the game's relative camera input.
    if (mouse->focus && [event window]) {
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
    }
    return;

    deltaX = [event deltaX];
    deltaY = [event deltaY];
'''),
    ("src/video/cocoa/SDL_cocoawindow.m",
     "    // On macOS 26 if you move away from a space and then back, mouse motion events will have incorrect\n",
     '''    SDL_SendMouseMotion(Cocoa_GetEventTimestamp([theEvent timestamp]), window,
                        mouseID, false, x, y);
    return; // Keep event coordinates instead of polling the desktop pointer.

    // On macOS 26 if you move away from a space and then back, mouse motion events will have incorrect
'''),
]

# Keep game state changes local; these entry points must not alter desktop state.
for name, signature, body in [
    ("SDL_cocoamouse.m", "static bool Cocoa_ShowCursor(SDL_Cursor *cursor)", "    return true;\n"),
    ("SDL_cocoamouse.m", "static bool Cocoa_SetRelativeMouseMode(bool enabled)",
     '''    SDL_Window *logicalWindow = SDL_GetMouse()->focus;
    if (logicalWindow) {
        Cocoa_HandleMouseWarp(logicalWindow->x + logicalWindow->w / 2.0,
                              logicalWindow->y + logicalWindow->h / 2.0);
    }
    return true;
'''),
    ("SDL_cocoawindow.m", "static void Cocoa_UpdateClipCursor(SDL_Window *window)", "    return;\n"),
    ("SDL_cocoawindow.m", "static NSCursor *Cocoa_GetDesiredCursor(void)", "    return [NSCursor arrowCursor];\n"),
]:
    anchor = signature + "\n{\n"
    CHANGES.append(("src/video/cocoa/" + name, anchor, anchor + body))


def main():
    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(SOURCE), *arguments])

    if git("rev-parse", "HEAD").decode().strip() != REVISION:
        raise SystemExit("Preserving SDL checkout: unexpected upstream revision")
    originals = {name: git("show", f"HEAD:{name}").decode() for name in {c[0] for c in CHANGES}}
    patched = dict(originals)
    for name, anchor, replacement in CHANGES:
        if patched[name].count(anchor) != 1:
            raise SystemExit(f"Expected one SDL insertion point: {name}: {anchor!r}")
        patched[name] = patched[name].replace(anchor, replacement, 1)
    for name, text in patched.items():
        if (SOURCE / name).read_text() not in (originals[name], text):
            raise SystemExit(f"Preserving unexpected SDL edits: {name}")
    header = (ROOT / "scripts/native/valimc_cua.h").read_text()
    if (SOURCE / HEADER).exists() and (SOURCE / HEADER).read_text() != header:
        raise SystemExit("Preserving unexpected SDL adapter header")
    for name, text in {**patched, HEADER: header}.items():
        (SOURCE / name).write_text(text)
    print("Prepared internal-pointer SDL backend; rebuild the dedicated client library")


if __name__ == "__main__":
    main()
