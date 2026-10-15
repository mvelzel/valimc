# Actual Minecraft validation

Use Minecraft **Java 26.3 / protocol 777**, app ID `local.valimc.minecraft-client`.
One dedicated testing subagent drives `mcp__cua_repl`; the primary continues work.
Read the tool's current documentation, not copied API snippets.

Launch a fresh client directly into the test server:

```sh
/usr/bin/python3 scripts/minecraft_client.py --evidence .local/client-tests/TICKET/run-01
```

Run this in a tracked `exec_command` session with `tty: true` and native macOS GUI
access (`sandbox_permissions: "require_escalated"` on this host). The helper uses the
installed official jars/assets, dedicated SDL wrapper and fixed loopback Quick
Play address. It creates a fresh game directory and uses the offline test identity
`ValiMCTest`; the local test server must use offline mode. Account files and normal
client settings are untouched. Console/game logs and fingerprints stay in the run.
Keep the default small windowed size and automatic UI scale; do not maximize or enter fullscreen.
The dedicated client starts muted (`soundCategory_master:0.0`).

After testing, Ctrl-C the owning terminal session with `write_stdin` and wait for
its completion; the helper terminates/waits for its own JVM. Confirm zero server
players. Reconnect tests stop the process and launch again with `run-02`, retaining
the server dataset. Never use the Launcher or navigate connection/server menus.

## Handoff and evidence

The handoff names the ticket, exact checkpoint/release, test dataset, scenarios and
private evidence directory `.local/client-tests/<ticket>/`. Keep its release frozen;
coordinate restarts/fixture changes. Verify the listener/release before stopping it.
Try enabled computer use even while the Mac is locked. If unavailable, leave the
scenario pending and continue independent implementation.

Baseline smoke for docs/research/workflow: join localhost, observe terrain, execute
`/stats`, verify the response and inspect fresh logs. Features add changed behavior,
negative cases and relevant recovery. Attempted input, host fixtures and native
codecs cannot stand in for the graphical action. Do not connect to unrelated servers.

The tester owns visual verification and reports date/version, PASS/FAIL per
scenario, actual actions, failure reasons and limits. The primary reviews the
report before Done/publication. Failures include reproduction steps, expected
versus observed behavior, exact checkpoint/dataset and relevant diagnostic logs
or traces for debugging and retesting. Routine saved screenshots, image hashes and
duplicate primary visual checks are unnecessary. Use CUA visual observations as
needed; save images only for useful failure diagnosis or when requested.
Useful raw logs/captures stay ignored; concise results go in
the ticket. Current gates are
listed once in [the roadmap](roadmap.md); completed evidence is in individual tickets.

## Input and fixtures

The [dedicated SDL backend](mouse-testing.md) handles pointer input internally.
No optional modes, fallbacks, desktop-position diagnostics or cursor unit tests.
Keyboard input can still activate the game; camera drag holds a button and can mine.
If window lookup fails, refresh the app binding from the generated bundle path.
Inspect fields before submitting text; retry dropped input without calling it a pass.

The user permits resetting the development game/world, items, builds and pose.
Keep account/launcher credentials and unrelated resources intact. Preserve source
journal/counters and destination receipts within a dataset; reset the whole dataset
rather than rolling back one committed side. See [workflow](development.md).

The generated Java wrapper is `.local/Minecraft Client.app`; rebuild instructions
are in [mouse testing](mouse-testing.md). Normal Launcher profiles stay unchanged.
