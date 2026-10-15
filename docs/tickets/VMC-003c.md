# VMC-003c — Direct test-client lifecycle

Status: Implementation checkpoint; actual client gate pending. October 15, 2026.

Every validation launches the dedicated vanilla client directly into the fixed
local ValiMC endpoint, tests it, then shuts that process down. Reconnect means a
fresh launch. No Launcher or server-list navigation. A fresh private game directory
contains no personal servers/options; installed jars/assets are shared read-only.

`scripts/minecraft_client.py --evidence .local/client-tests/TICKET/run-01` runs in
a tool terminal session. It uses installed 26.3 version metadata and native
`--quickPlayMultiplayer`, the mandatory SDL app wrapper, and the fixed offline
identity `ValiMCTest` for the local offline-mode test server. No account credentials
are read. Ctrl-C the owning session terminates/waits for its own JVM. One lifecycle
lock prevents competing dedicated clients; logs/fingerprints/exit status stay private.

Acceptance: actual direct join/render/stats, movement and pointer use, shutdown
with zero local players, second fresh direct launch with the same server identity,
then shutdown. Record PID/backend/server/source evidence and limits. No actual
client gate is inferred from argument construction or a native oracle.

Motivation: a saved-row click after a screenshot-size change selected an unverified
server during VMC-015b2. That ground reconnect is invalid; its feature gate stays
open. The new workflow removes server-menu selection entirely.

First run exited during SDL initialization before joining; no GUI input occurred.
Its owned JVM is gone and the server has zero players. A rejected simulation-
distance value was corrected to the native minimum 5; retry needs native GUI
access outside the shell sandbox. Failed evidence stays in `.local/client-tests/VMC-003c/run-01/`.

Two subsequent direct launches joined, rendered, accepted movement/pointer input
and shut down cleanly using native GUI access. The helper now omits custom
resolution arguments and explicitly disables fullscreen, preserving Minecraft's
default small window. One final default-size launch/capture/shutdown check remains.
