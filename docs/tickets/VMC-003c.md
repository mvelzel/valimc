# VMC-003c — Direct test-client lifecycle

Status: Done (`44f2fd9`); primary reviewed actual-client evidence October 15, 2026.

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

Checks: helper syntax/installed-metadata argument construction pass. Actual runs
02/03 automatically joined the frozen `18aad55` server, rendered, accepted movement,
showed `/stats` and switched inventory tabs through SDL. Each owned shutdown left
no JVM and zero local players. No connection-menu input was used.

Runs 04–06 verified the default small window (1708×960 Retina render pixels),
readable native Auto UI scale and owned shutdown. Run 06 started with master
volume 0 before joining or GUI input; the setting remained 0 after exit. The helper
writes these launch settings; sound menus are unnecessary. Auditory output was not
independently measured. Empty inventory prevented an owned-stack gesture check.

Evidence: `.local/client-tests/VMC-003c/report.md`, per-run logs, manifests, original
F2 images and SHA-256 indexes. First run's pre-join SDL abort remains recorded;
corrected simulation distance 5 plus native GUI access passed subsequent runs.
Run 05 opened Options before the launch-only sound clarification; no sound-setting
input occurred. This lifecycle gate does not close saved-velocity/gameplay gates.
