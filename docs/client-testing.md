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

VMC-005b2b: actual 26.3 CUA double-clicks collected patched stone 50 to cursor
64 by consuming partial 7 and 7 of 9, retaining the full source 64 and incompatible
plain 7. Placement retained glint/custom NBT. Eggs 8 collected to 16 with 2
remaining from source 10. Q/drop correction and reopen preserved both results.
Owner reads confirmed counts/patches and empty final cursor; client logs contain
no codec errors. Fixtures populated accepted items and selected the ordinary UI;
server gameplay remained creative. All 71 tests, release and full oracle pass,
including a new harness invoking Mojang's actual collect algorithm. See the ticket
for the harness's limited ordinary-slot scope and later inventory requirements.

VMC-005b2c: normal-handler clone/fill fixtures displayed source 7 unchanged,
cursor 64 and filled main slots 9/10 at 64; actual CUA placement accepted the
clone. Denied fixtures after a trusted permission change preserved items and
empty targets; actual CUA half pickup/placement preserved 3/4 and patches.
Creative inventory-tab middle-click/placement also displayed a full clone, but
client bytecode and empty owner cursor show that tab uses local clicks followed
by creative-slot writes. It does not validate the ordinary server CLONE input.
All 77 tests, release and full Mojang oracle pass, including start-time permission
sampling. Generic-container CLONE and sustained creative-fill input remain pending;
the ticket is parked and unpushed. Client log has no codec/ERROR entries. See
`tickets/VMC-005b2c.md` for exact actions, fixture distinctions and remaining scope.

VMC-005b2d1: actual CUA keyboard close/reopen returned cursor 7 to hotbar,
merged cursor 17 through selected/offhand/storage priority, and returned grid
eggs 3. Full storage retained selected 63/cursor 10/grid 3 with a limitation
message; after a capacity fixture, actual close/reopen returned 1/9/3 and cleared
cursor/grid. Owner counts and custom NBT agree with screenshots. All 86 tests,
release and full oracle pass. Pickup setup used normal-handler fixtures because
coordinate clicks failed with `noWindowsAvailable`; app rebinding/Raise/REPL
reset did not repair them, while screenshots and keyboard input worked. Coupled
actual mouse pickup remains pending. This ticket is parked/unpushed, and actual
world drops remain unimplemented. Client log has no codec/ERROR entries.

VMC-018a: actual Minecraft 26.3 rendered a private patched-stone item fixture,
changed it to eggs after metadata update, and removed it after a removal packet.
A second nonzero-velocity spawn, zero motion update and pickup-animation packet
were accepted; the item disappeared before explicit cleanup. Transient animation
timing and physics trajectories were not captured. Final bounded helpers repeated
render/update/remove successfully. Owner inventory remained empty, all fixture
entities were cleaned up, and logs have no codec/ERROR entries. All 92 tests,
release and Mojang's 272 velocity/25 complete packet cases pass. This completes
the wire foundation; actual gameplay item ownership/drop/pickup remains future work.

VMC-018b, October 14: production release restarted at 00:09 on localhost:25565.
Actual 26.3 joined via CUA keyboard navigation. Region API admission created a
stationary patched stone item; its ETS snapshot produced the visible item without
connection packet injection. Stack CAS changed it to eggs; a stale revision was
rejected. Actual disconnect/reconnect showed the current egg, then owner removal
cleared it. A second stone disappeared after region termination/recreation; the
new owner rejected the old incarnation and actual `/stats` remained responsive.
Both fixtures are cleaned up and inventory remains empty. All 102 tests, release
and full Mojang oracle pass; private logs contain no codec/ERROR entries.
Screenshot access recovered through exposed Raise, while coordinate clicks still
fail with `noWindowsAvailable`. Earlier mouse gesture gates remain pending.
This validates ephemeral stationary ownership/replication; physics, persistence
and inventory-drop/pickup transactions are still required.

VMC-005c1, October 14: the updated release started at 00:24. The actual client
loaded its 88-byte legacy pose without an inventory. Normal-handler fixtures
prepared patched stone 7, helmet, shield, hotbar stone 23 and eggs 3; CUA keyboard
3 selected the third hotbar slot. Ordinary-menu UI fixtures showed those contents.
Actual disconnect/rejoin and a full graceful release restart at 00:27 restored
the same contents/selection; owner/file reads confirmed exact NBT and removals.
A carried stone 7/grid egg 3/pending-drag fixture survived a controlled graceful
session close and actual rejoin. Its ordinary UI showed cursor/grid contents,
while owner/file reads confirmed the gesture was reset. This is preview recovery,
not a vanilla disconnect-drop or actual mouse-pickup pass.
A backed-up checksum-corrupt file made actual join display the storage rejection;
the corrupt bytes were preserved. Restoring the exact backup allowed actual join
and recovered the exact fixture state. All fixture contents were cleared through
normal close/creative handlers, keyboard 1 restored selection, preview UI was
restored, and an empty version 2 checkpoint (139 bytes) was verified. Actual
`/stats` remained healthy. All 111 tests, release/oracle and private log checks pass;
the log has no codec/ERROR entries. Earlier mouse-validation gates remain pending.

VMC-019a, October 14: updated release started at 00:49. Actual CUA keyboard join
rendered region-created patched stone 7, then eggs 3 after stack replacement.
File assertions matched each accepted API result. Graceful region replacement
recovered the same UUID/position/patches with a new runtime handle; the old epoch
was rejected, and the egg remained visible. A full release restart at 00:53 and
actual rejoin rendered that same item without reseeding; owner/file comparisons
confirmed exact state. Removal produced an empty 55-byte item file and visible
disappearance. Another full restart at 00:55/rejoin left it absent; UUID lookup
returned missing and inventory remained empty. Client log has no protocol/codec/
duplicate-entity/ERROR entries. All 122 tests, release/oracle and audit pass.
Window observation needed rebinding/Raise once; one screenshot call returned slowly
but succeeded. No mouse-input, trajectory, pickup or inventory-drop claim follows.
