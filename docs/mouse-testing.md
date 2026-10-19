# Minecraft computer-use client

Launch Java 26.3 with `scripts/minecraft_client.py`; see [client testing](client-testing.md).
App ID `local.valimc.minecraft-client`; one dedicated testing subagent owns CUA.
Harness-specific tools are listed in [client testing](client-testing.md#harness-tools).

Its local SDL backend consumes event positions for menu targeting and camera
deltas. Desktop cursor warps, association, visibility changes and confinement are
disabled. The dedicated launcher always loads this backend; there are no mouse
modes or fallback flags. Minecraft classes and normal Launcher profiles are intact.

## Build

Keep SDL source/license under ignored `research/tools/SDL`, pinned to
`ab5541ec5d4377dcc20a701897437f07ba71566f`. Build products stay in `.local/`.
The patcher preserves unexpected source edits and refuses other revisions.

```sh
python3 scripts/patch_sdl_mouse.py
cmake -S research/tools/SDL -B .local/sdl-mouse-build -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_STATIC=OFF -DSDL_SHARED=ON
cmake --build .local/sdl-mouse-build --parallel 8
python3 scripts/prepare_minecraft_client.py
```

Start a new direct client after rebuilding. Startup prints
`ValiMC internal-pointer backend`. Never overwrite its library during a test.

## Use and verification

Use the harness's computer-use tool (Codex `mcp__cua_repl`) or the input bridge for
every UI action. The tester checks ordinary menu clicks,
inventory pickup/place, opposite camera drags, commands and fresh logs. Reconnect
by stopping the owned process and launching a fresh direct client, never a menu.
Camera `drag` holds a button and can mine blocks. For camera-only checks, stage
the player facing the sky; do not drag across the block being verified.
While an inventory screen is open, click its own hotbar row, not the HUD hotbar
below the screen: a click outside the screen throws the carried stack.
For input across captures/actions, F8 toggles logical use/right-button hold and
F9 toggles attack/left-button hold. Press the same key again to release before
menus or the next scenario. Key repeat does not toggle; a fresh client starts
released. These dedicated adapter gestures never touch the desktop pointer.
Do not add desktop-position diagnostics, cursor assertions or compatibility modes.
Keyboard input can still activate Minecraft; this backend isolates pointer
handling and does not promise foreground isolation.

## Input bridge

When `VALIMC_INPUT_SOCKET` is set, which `minecraft_client.py` always does, the backend also listens on
`.local/minecraft-input.sock`. `scripts/minecraft_input.py` sends a batch of commands
(click, drag, look, press/down/up, scroll, key/keydown/keyup, type, wait, release,
state). The game consumes them as SDL events on its own event pump, with logical
window focus and without activating the app or touching the desktop pointer or
keyboard. Coordinates are window-screenshot points, title bar included. It adds a
channel; Cocoa event handling and the F8/F9 toggles are unchanged. Batches are
bounded (16 KiB, 512 actions, 60 s), and the socket is owner-only and removed on stop.
Minecraft discards the first motion after the pointer enters or the mouse is
captured; the bridge spends those discards on no-op motions so `look` stays exact.
It also separates a click's move from its press by 100 ms, so closing a screen
does not turn the camera. The patched Cocoa path still sees the user's real cursor when it
crosses the visible test window, so leave that window covered or out of the way.
[VMC-003e](tickets/VMC-003e.md) records its validation.

[VMC-003b](tickets/VMC-003b.md) records the current implementation and GUI gate.
Older input investigation is retained in Git history and [VMC-003](tickets/VMC-003.md).
