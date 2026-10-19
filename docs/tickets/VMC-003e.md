# VMC-003e — Background input bridge for Claude Code

Status: Done within dual-harness input scope at `5863974`; both client gates pass.
Depends on: [VMC-003b](VMC-003b.md), [VMC-003c](VMC-003c.md).

Claude Code must validate the dedicated client from a subagent, in the background,
while the user keeps using the Mac and the primary keeps working. The Codex
workflow, `mcp__cua_repl`, the Cocoa pointer path and F8/F9 toggles stay unchanged.

Finding (Claude desktop app, October 19, 2026): background `app_*` tools only
capture the window. Clicks are refused as "canvas", drags as non-text, and every
key including Escape and F8/F9 is refused. Full-screen `computer_batch` aborts with
"user interrupt" inside subagents but works in the main session, and it takes over
the user's screen. These are host policies, so the fix lives in the dedicated client.

Scope: the patched SDL serves `.local/minecraft-input.sock` when `VALIMC_INPUT_SOCKET`
is set. `scripts/minecraft_input.py` sends bounded command batches, which become
SDL events on the game's own event pump. They give logical keyboard/mouse focus
without activating the app or touching the desktop pointer. Coordinates are
window-screenshot points. `minecraft_client.py --no-activate` launches without
taking focus. Claude Code gets `CLAUDE.md` and the `minecraft-tester` agent, and
the docs map each harness's tools.

Acceptance:

- From a Claude subagent, with only background screenshots, the bridge drives:
  chat commands, creative inventory pick/place and shift-click, menu buttons,
  camera in both directions at the exact sensitivity, break/place, movement,
  flight, reconnect, and cleanup of the JVM and socket.
- Closing a screen with a click does not turn the camera. The first `look` after
  the pointer enters or the mouse is captured is not lost.
- `--no-activate` keeps the user's app frontmost, and input still reaches the window.
- The bridge refuses malformed or oversized batches clearly. Without the
  environment variable it stays off, and Codex launches are unchanged.

Reference: pinned SDL `ab5541ec5d4377dcc20a701897437f07ba71566f`
(`Cocoa_PumpEventsUntilDate`, `SDL_SendMouseMotion`, `SDL_SetMouseFocus`,
`SDL_HINT_MAC_BACKGROUND_APP`, `SDL_HINT_WINDOW_ACTIVATE_WHEN_*`).
Minecraft 26.3:
- `SDLEventHandler.handleMouseMotionEvent` passes `xrel/yrel` to `MouseHandler.onMove`.
- `onMove` honours `ignoreFirstMove`, which `cursorEntered` and `grabMouse` set.
- When not captured, it accumulates absolute deltas, which `handleAccumulatedMovement` applies after a same-frame grab.

Checks: patch application, native build (no new warnings), `py_compile`, bridge
`state` and parse errors, public-tree audit, `git diff --check`. Library SHA-256:
`48f54a50646631e9e2c10d32ca42981898cebc4d8df9c8b88acd6ed334e5c086`.

Client: release `valimc_spike` built from `900e0c4`, disposable creative world under
`.local/claude-spike/`, evidence under `.local/client-tests/claude-harness-spike/`.
A Claude subagent drove every run in the background while the user worked.
- bridge-run-01 (October 19) passed chat, inventory/shift-click, menus, camera
  direction, break/place, movement/flight and reconnect. It found two defects: a
  click that closed a screen turned the camera, and some look steps were lost.
- bridge-run-03 confirmed the click fix. It also showed a lost first look after
  re-capture, and that the activate hints alone did not prevent the focus steal.
- bridge-run-04 passed every remaining check:
  - The user's app stayed frontmost throughout, with the window never activated
    but captured and receiving input (`/stats` reply, creative pick into the hotbar).
  - Four re-capture paths each turned exactly +30° from `look 200 0 1`, and
    reverse looks turned exactly -30°.
  - Escape → Options → Done → Back to Game did not rotate the camera.
  - Cleanup left no JVM and no socket, with exit 143 and 0 players.
Limit: the user's real cursor crossing the visible test window still reaches the
patched Cocoa path. The off-Space capture path was not exercised.

Codex acceptance (2026-10-19, Java26.3/protocol777): dedicated medium-reasoning
tester reports PASS on `5863974`, unchanged direct launch and the same SDL hash
above, using only `mcp__cua_repl`. Join, visible `/stats`, menu click, creative
Oak Slab pickup, two right clicks forming a double slab, F9 breaking it, F8/F9
release and complete inventory/cursor disposal pass. A fresh second client,
host-staged facing the sky, passes opposite camera drags: yaw0→14.7→-15.3 with
visible opposite cloud movement. This is a functional baseline, not an exact
sensitivity comparison. Evidence: `.local/client-tests/runner-slab-smoke/`.

Initial camera attempts mined disposable blocks because drag holds attack; this
is documented input behavior, not an observed runner regression. The tester read
the pointer guide late; handoffs now require both guides before input, and
camera-only checks use a sky-facing pose. No runner implementation changed.
Both owned clients and servers stopped/waited; JVM PIDs gone, input socket absent
and port25565 clear. No live player-registry count was queried on the unnamed
server. Both Claude and Codex acceptance gates are closed; retain the cursor/
off-Space limits above.
