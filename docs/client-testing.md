# Actual Minecraft validation

Use Minecraft **Java 26.3 / protocol 777**, Launcher installation
**ValiMC computer-use test**, app ID `local.valimc.minecraft-client`.
One dedicated testing subagent drives `mcp__cua_repl`; the primary continues work.
Read the tool's current documentation, not copied API snippets.

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

The tester reports date/version, fingerprints, actual actions, observed state,
logs and limitations. The primary reviews evidence before Done/publication. Raw
logs/captures stay ignored; concise results go in the ticket. Current gates are
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

The generated helper is `.local/Minecraft Client.app`; rebuild/setup instructions
are in [mouse testing](mouse-testing.md). Normal Launcher profiles stay unchanged.
