# Minecraft Java 26.3 client testing

Date: October 13, 2026. Local address: `localhost:25565`.

The running graphical client's `logs/latest.log` recorded a connection at 17:31:51 and a `Network Protocol Error` during configuration. The cause was missing vanilla registry tags, including `minecraft:infiniburn_overworld`, enchantment item tags, and sulfur-cube archetype tags. ValiMC had sent an empty `update_tags` packet.

The server now sends 773 resolved vanilla tags across 15 registries. The payload is encoded once at application startup and shared as an immutable binary between connections. Static registry IDs come from Mojang's built-in registries; synchronized dynamic registry IDs match ValiMC's alphabetically ordered entries.

The previous oracle validated packet syntax using prebuilt vanilla registries. It could therefore pass while the graphical client's registry dependency loading failed. The oracle now loads the actual received entries and tags through Mojang's `RegistryDataLoader` with the vanilla data pack. This strengthened test failed against the old running server and passed against the fixed server, including all 32 synchronized registries, 49 chunks, two players, movement, ordinary creative block placement/breaking, and commands. All 17 ExUnit tests also passed.

The user confirmed that the flat world rendered after the fix. Computer use initially rejected the unbundled Java process. A local macOS app launcher using the existing official Java runtime made the game discoverable as `local.valimc.minecraft-client`. The separate Launcher installation is **ValiMC computer-use test**. Screenshot capture, mouse navigation through Multiplayer, localhost join/rendering, and keyboard `/stats` execution were then observed through computer use. The displayed response included one player, eight regions, ten schedulers and 63 MiB. This confirms these specific GUI scenarios; it does not establish all creative or survival mechanics. The test server uses `/tmp/valimc-client-test-world`.

The repeatable setup and verification process are documented in `development.md`. Ticket records below will add fresh evidence for each checkpoint; private captures belong under `.local/client-tests/`.

VMC-001: regenerated the local app helper, restarted Minecraft through the
dedicated Launcher profile, rejoined localhost, observed terrain and `/stats`.
Workflow/research checkpoint `4f948be` was pushed.

VMC-002: the rebuilt production release advertised help/spawn/stats. Actual
26.3 screenshots showed `/sta` Tab completion, stats execution, the three-command
suggestion list, help output and rejection of `/stats extra` and `/missing`.
F3 verified movement to X = -3.382 and `/spawn` returning to 0.500 / 64.000 /
0.500. A dropped text-input attempt was retried with exact-field verification.
See `tickets/VMC-002.md` for automated/oracle evidence and remaining scope.

Locked-session validation resumed after the user's authorization. The opt-in
SDL event-position adapter provides camera rotation and targeted inventory
clicks. The pinned build, reproduction commands and observed angles are in
`mouse-testing.md`. VMC-003's reconnect/restart/spawn GUI scenarios pass; a fresh
phase-transition batch failure remains a code follow-up. VMC-004b1 passed
creative custom-NBT preservation, placement, deliberate depth rejection and
reconnect. VMC-005b1's ordinary half pickup passes, but carried-item quick-craft
and later GUI checks remain pending. These results distinguish injected fixture
setup from actual computer-use actions and authoritative state checks.

VMC-003a reproduced and fixed the configuration-to-play batch save failure.
After rebuilding, actual client movement/rotation and a local valid-pose/bad-frame
fixture displayed the expected rejection. Rejoin restored XYZ -3.115 / 64.000 /
-0.211 and yaw/pitch 104.7 / 47.8; all fields matched the fixture exactly. `/stats`
worked and the client log had no codec errors. Deterministic connection tests
separately cover the precise phase-transition boundary and failed configuration
without overwriting a prior save. VMC-003's remaining gate is now complete.

Publication validation, October 13, 2026: actual Minecraft 26.3 with the rebuilt
SDL event-position adapter joined localhost after a release restart. Fixtures
supplied component metadata and an ordinary-menu UI; all menu operations below
were CUA actions, with server gameplay still the creative preview. Half pickup
split 17 into 8/9, right placement wrote one and retained 8, merging recovered
17, shift transfer and number 1 moved it between main/hotbar, F put it in offhand.
Q/drop restored 17 with an explanatory message; reopen retained accepted slots.
Owner reads confirmed counts, empty cursor, identical custom NBT and glint.
Pressing 2 selected the egg (owner index 1). Creative pickup/trash cleared the
first hotbar slot in both the screenshot and owner state. Scalar fixture counts,
Stone tooltip, sword damage bar and unsupported-name restoration were also
observed. VMC-004a, VMC-005a and VMC-005b1 now satisfy their client gates.

VMC-005b2a passed 65 tests, production build and Mojang quick-craft TCP codecs.
A normal-handler fixture rendered three stacks of 5 and cursor 2; a CUA click
returned that remainder. Sustained multi-slot CUA gestures remain unverified:
short/long drags and held-click/motion attempts produced endpoint pickup packets.
The ticket remains pending that gate, even though the user explicitly requested
publishing all checkpoints to main. Absolute menu targeting was fixed separately
in the isolated SDL adapter; see mouse-testing.md. Final CUA `/stats` response:
one player, four regions, ten schedulers, 78 MiB. Client logs have zero Network
Protocol Error, DecoderException, EncoderException or ERROR entries; the private
copy stays under `.local/client-tests/VMC-005b2a/`.
