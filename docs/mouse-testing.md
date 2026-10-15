# Minecraft computer-use client

Use the Launcher installation **ValiMC computer-use test**, Java 26.3, app ID
`local.valimc.minecraft-client`. One dedicated testing subagent owns CUA.

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

Restart the dedicated installation after rebuilding. Startup prints
`ValiMC internal-pointer backend`. Never overwrite its library during a test.

## Use and verification

Use `mcp__cua_repl` for every UI action. The tester checks ordinary menu clicks,
inventory pickup/place, opposite camera drags, commands, reconnect and fresh logs.
Camera `drag` holds a button and can mine blocks; use the disposable test world.
Do not add desktop-position diagnostics, cursor assertions or compatibility modes.
Keyboard input can still activate Minecraft; this backend isolates pointer
handling and does not promise foreground isolation.

[VMC-003b](tickets/VMC-003b.md) records the current implementation and GUI gate.
Older input investigation is retained in Git history and [VMC-003](tickets/VMC-003.md).
