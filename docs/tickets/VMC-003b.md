# VMC-003b — Isolate the Minecraft test pointer

Status: Done. October 15, 2026.

Extend the dedicated SDL input adapter so computer-use events update Minecraft's
logical pointer without moving, hiding, capturing or confining the user's desktop
cursor. Keep ordinary profiles unchanged. Do not modify Minecraft classes.

Acceptance:

- The dedicated client always uses this backend, with no pointer modes, fallback
  or compatibility switches. Preserve pinned upstream/license and unexpected edits.
- Suppress backend OS warps, mouse association, hide/show and confinement in this
  backend while retaining correct internal absolute/relative input and button order.
- Dedicated tester uses actual 26.3/CUA: menu transitions, clicks in an open menu,
  inventory targeting/pickup/place, opposite camera drags, controls, reconnect and
  fresh logs. No desktop-coordinate diagnostics or cursor-position unit tests,
  as explicitly requested by the user. Record observed interference candidly.
- Verify patch application, native build, format/tests/release, diff/public audit.
  Commit locally after automated checks; publish after the client gate passes.

Reference: pinned SDL `ab5541ec5d4377dcc20a701897437f07ba71566f`, Cocoa mouse,
window and cursor backend; pinned 26.3 `InputConstants.grabMouse/releaseMouse`.
Original adapter and history: `scripts/patch_sdl_mouse.py`, `docs/mouse-testing.md`.

The user explicitly requested the simplest working dedicated backend on October
15: no opt-ins/outs, fallbacks, backward compatibility or desktop-position tests.
Removed the initial optional diagnostics prototype before any client launch.

Implementation/checks: the dedicated backend keeps event-based absolute and
relative coordinates, skips native cursor visibility/capture/confinement, and
intercepts Cocoa warp/association calls. Plain launcher generation requires this
local library. Native build, Python compilation, repeated patch application,
format, 439 tests and production release pass. No protocol/server changes or new
cursor tests. Build SHA-256: `d30dfc688a4a0424fe5e1815a9d0c629695d75d10ea3419dccf29a41acc4ed3a`.
The retained upstream physical-button reconciler is unused (one compiler warning).
Dedicated tester passed actual 26.3/CUA validation, 09:29–09:34 CEST, with the
unchanged release/dataset `/tmp/valimc-014b5b-client-20261014`. Startup confirmed
the backend marker and the library hash above. Menu/Controls clicks, creative
selection, owned-inventory pickup/place, opposite camera drags, movement,
disconnect/rejoin and `/stats` passed. Reconnect retained the selected item;
fresh logs contain no errors or decoder exceptions. Camera drag mined one
disposable grass block because it holds the primary button.

Evidence: ignored `.local/client-tests/VMC-003b/report.md`, fresh log, library hash
and final runtime snapshot. No desktop-position diagnostics were used. Escape
visibly activated the game's title chrome; keyboard/foreground isolation is not
established. The implementation removes backend cursor manipulation; this test
does not establish comprehensive desktop noninterference.
