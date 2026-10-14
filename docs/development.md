# Development and verification process

Target: full vanilla Java **26.3 / protocol 777** compatibility. The current
creative preview was committed at `4495775`. The user requested direct commits
and normal pushes to `main` on October 13, 2026, superseding the initial
`codex/minecraft-implementation` branch workflow. No PR is required. The roadmap
is a backlog, not implemented parity.

## One ticket, one verified checkpoint

1. Pick the first implementable ticket from `roadmap.md`, splitting large entries first.
   Write a concrete before/after behavior, dependencies, ownership design,
   acceptance criteria, regression tests, and actual-client scenario in its record.
2. Establish vanilla behavior from the pinned version's classes/codecs, bytecode,
   private decompiled source or differential scenarios. Check Paper's deliberate
   changes. Read relevant Pumpkin/SteelMC/other implementations for design ideas
   and omissions. Record sources and conclusions, not copied source text.
3. Implement original Elixir code with explicit owners, ordering, bounded work,
   and failure semantics. Avoid a new global coordinator on a gameplay hot path.
4. Exercise positive behavior, invalid input, and relevant concurrency/durability
   boundaries. Run the checks below once; repeat after edits, failures, or an
   unresolved concern. Use temporary worlds and loopback listeners.
5. After automated checks, review the exact diff/public-tree audit and make a
   local ticket checkpoint. The user permits committing before manual validation;
   mark the GUI gates pending and keep this checkpoint unpushed.
6. Restart the local server gracefully and reconnect actual Minecraft 26.3 using
   computer use. Exercise the changed behavior, inspect resulting screenshots,
   and check client/server logs. Test reconnect/restart if persistence is involved.
7. Record evidence and limitations, update roadmap/compatibility notes, review
   the diff and public-tree audit, amend the unpushed ticket checkpoint if needed,
   and push `main` after required client checks pass. An explicit user request
   to publish checkpoints can override withholding a push; it does not turn
   pending tests into passes. The October 13 request to push all work includes
   VMC-005b2a's automated-verified checkpoint with its gesture gate still pending.
   Done means every required check and client scenario passed. A failed push
   remains an unpublished local checkpoint until a normal retry succeeds.

The user enabled and authorized locked-session computer use on October 13, 2026;
Launcher and actual Minecraft access were observed while locked. Try the enabled
session. If access is unavailable, continue independent implementation/research/
automated checks and retain pending client scenarios. Never amend an
already pushed checkpoint or mark a ticket Done just because automated checks pass.
Park tickets at `Awaiting client validation` after their automated checkpoint and
continue the next implementation slice. Tested foundations can support dependent
work while their GUI gates remain explicit. Only one ticket is being implemented
at a time; the manual-validation queue can contain several tickets. Fix a known
blocking defect before relying on that behavior. The user explicitly requested
continued progress across tickets while computer use is paused.

```sh
mix format --check-formatted
mix test
python3 scripts/check_vanilla.py  # required for protocol/registry changes
MIX_ENV=prod mix release --overwrite
python3 scripts/audit_public_tree.py
git diff --check
git diff --stat
# Stage explicit ticket paths, review git diff --cached, commit, then push.
```

The server runtime needs no JVM. Our Java 25+ development oracle checks actual
Mojang packet codecs and network registry/tag dependency loading. This is valuable
independent evidence, but cannot establish rendering, controls or survival parity.
Item checks generate nine stack fixtures with Mojang's codecs, decode and
cross-convert them in Elixir, then ask Mojang to decode the resulting bytes and
compare semantic equality in both ordinary and delimited formats. A focused
inventory behavior harness also invokes Mojang's actual menu methods to verify
collect ordering, direction, triggers, caps, ordinary-slot component preservation,
creative clone/fill permissions, start-time fill authorization and the actual
inventory-return method's selected/offhand/storage order and overflow effects.
It uses a constructor-free test player only within that development harness.
The return harness captures requested drops without simulating item entities.
World/player lifecycle and equipment locks require their own tests. Temporary
fixtures are not committed. Mojang also decodes Elixir text containing NUL and
supplementary Unicode. TCP scenarios then exercise slot updates/corrections.

Entity checks generate 272 packed-velocity fixtures, including a deterministic
random sample and threshold/continuation/clamping boundaries. Elixir independently
encodes them and 25 complete entity packets; Mojang decodes the results. Velocity,
spawn, float32 angles, motion, pickup and removal must match exact bytes. Metadata
compares typed accessor values and exact stack patches after decoding because
component-patch entry ordering is not canonical. Regenerated public entity facts
must match the pinned extraction; temporary fixtures stay private. Graphical item
fixtures establish rendering/update/removal only, not drop/pickup economy or physics.

Region item checks additionally exercise the owner API, protected ETS publication,
CAS races, stale incarnations, count/byte limits, round-robin replication pacing,
loaded-chunk filtering, late observers, visibility changes and owner loss through
actual TCP sessions. Graphical VMC-018b scenarios create through that region API,
not a connection packet fixture; reconnect must observe current owner state and
region replacement must clear the old item while the session remains healthy.
Stationary scene items never authorize consuming inventory. With storage enabled,
VMC-019a writes bounded item records through the region writer before publication
or reply. Tests exercise unpublished pending state, busy admission, writer loss,
deadline/shutdown ambiguity, corrupt-file preservation and a committed proposal
whose acknowledgment is withheld. Recovery must read the actual file and never
overwrite it with the old owner snapshot. Actual Minecraft must observe region/
release recovery without reseeding, then durable removal through another restart.
Nil storage retains ephemeral test behavior. Item files/captures remain ignored.

VMC-019b1 inbox tests also cover canonical exact/conflicting/stale retries, retained
receipts after removal/recovery, multi-item atomic admission, count/byte/source
limits, version 1 migration, receipt corruption, bounded CPU worker saturation/loss/
deadline and physical commit with withheld acknowledgment. Actual Minecraft must
render the internal fixture, retain one entity on retry, then remain clear after
removal/retry and full restart/retry. This is destination evidence, not a player
outbox or actual Q/drop-control test. Fixture source UUIDs are separate from real
player sequence history. Never purge receipts to bypass a capacity failure.

Player persistence checks cover versioned pose/inventory encoding, exact supported
patches/removals, selection, invalid/truncated/oversized files, read-only legacy
migration, session authority reset and UUID writer leases. TCP scenarios assert
reconnect/shutdown recovery, one immutable checkpoint while the writer is stalled,
newer edits at final close and accepted inventory frames preceding malformed input.
Actual Minecraft checks use keyboard selection/disconnect/rejoin and a full release
restart; reversible corrupt-save fixtures must be backed up and restored exactly.
Carried/grid fixture recovery is recorded separately from vanilla menu cleanup.

Source-outbox tests (VMC-019b2) validate conservation, bounded version 3/legacy
files, monotonically retained sequence, changing writer fences, foreign/stale
requests, pending/close preservation, actual destination receipt proof (including
ephemeral storage rejection), transfer write failures and lost prepare/complete
replies/owner loss/reopen. Current login must preserve/reject pending state until
automatic reconciliation exists. The real-client scenario uses an explicitly
offline API fixture, checks pending-login rejection/file identity, completes
source/destination recovery, observes retained inventory/item rendering and
restart, then restores fixture inventory while preserving the advanced sequence.
Never restore a pre-transfer source backup alone after the destination commits.

VMC-019b3a adds automatic pre-login recovery. Tests stall region storage, saturate
the bounded I/O pool, kill a submitted worker, force a deadline/disconnect, inject
stale replies/timers and reject corrupt/ephemeral/conflicting/superseded targets.
The source file/UUID lease must remain intact while login is unpublished, and
unrelated sessions must respond. Already-delivered/removed intents must clear
without another entity. The real client starts from a prepared offline fixture,
recovers through actual login without manual delivery, survives restart, then
repeats after item removal with a same-sequence/depleted-inventory pending fixture
representing an uncommitted source clear. This deliberately retains sequence and
inventory ownership; restoring a pre-transfer inventory/counter remains prohibited.

VMC-019b3b routes in-world keyboard drops through source prepare/delivery/clear.
Tests stall both writers, attempt inventory mutations and placement, advance
movement, inject stale replies, reject drops during periodic saves, and recover
disconnect/deadline outcomes after possible delivery. Disabled/failed source
storage must not create an item. Mojang's selected-stack method verifies single/
all/empty counts and supported component identity; the codec TCP oracle sends
the actual drop actions and decodes depleted contents and exact item metadata.
Actual Minecraft must generate Q/Ctrl+Q, render the stationary preview items,
retain counts across reconnect/restart and correct selection/swap during a
stalled transfer. Preserve source counters/receipts when cleaning fixtures.

VMC-019b3c adds effect-aware ordinary menu click plans. Mojang's actual methods
verify slot THROW, outside PICKUP/QUICK_MOVE, signed nonzero throw buttons,
cursor/empty no-ops and quick-craft interruption in both permission modes. TCP
tests also forge predictions, stall source/destination, gate repeated clicks/
close/swap, reject effectful clicks during normal saves and recover depleted
cursors after disconnect or malformed input. The official-codec oracle decodes
exact cursor/slot changes and component-preserving item metadata. Actual client
coverage must use the ordinary inventory screen; creative tabs send different
drop/add packets. A development-only UI game-mode fixture does not implement
survival rules. Actual pickup/outside-click gates remain pending when CUA rejects
mouse actions; fixture cursor setup or codec tests cannot replace those gestures.

## Actual Minecraft computer use

The normal macOS game runs as an unbundled `java` process, absent from computer
use's app inventory. A tiny local macOS launcher invokes the existing official
runtime's `libjli` inside a real app bundle; it does not modify Minecraft classes
or the signed official runtime. Generate it with:

```sh
python3 scripts/prepare_minecraft_client.py
```

Use the separate Launcher installation **ValiMC computer-use test**, Minecraft
26.3, with the printed Java executable path. Generated helper files and
machine-specific paths stay in ignored `.local/`. The normal **Latest release**
installation retains its original Java setting. Regenerate the helper if the
official runtime moves or changes.

```js
var minecraft = await cua.getApp("local.valimc.minecraft-client");
await minecraft.getAXStateAndScreenshot();
// Derive coordinates from the current screenshot: the game canvas lacks AX controls.
await minecraft.pressKey("t");
await minecraft.getAXStateAndScreenshot();
await minecraft.paste("/stats", {format: "text"});
await minecraft.getAXStateAndScreenshot(); // Verify exact field text before submitting.
await minecraft.pressKey("Return");
await minecraft.getAXStateAndScreenshot();
```

The game can drop rapidly batched text input. Inspect the focused field before
Return; retry via paste when needed. Menu clicks may only hover a button; use
observed Tab/Shift+Tab focus and Return when that occurs. Attempted input is not
evidence of the intended behavior.

See `mouse-testing.md` for the bundled SDL's mouse limitations and the isolated
Cocoa event-position adapter. Record the actual native input backend used
in GUI tests; seeded pose fixtures do not prove mouse-generated rotation.

Use localhost:25565 and a separate test world, for example:

```sh
VALIMC_WORLD=/tmp/valimc-client-test-world mix run --no-halt
```

Gracefully stop through a release command or a verified server PID, never an
assumed PID. Closing Minecraft does not stop ValiMC. Do not change the user's
resource packs/controls to hide defects or connect to unrelated saved servers.

Baseline smoke for research/docs/workflow: capture title screen, open Multiplayer,
join localhost, observe terrain, execute `/stats`, confirm the response. Feature
scenarios add their changed behavior and relevant negatives. Keep optional
screenshots under `.local/client-tests/<ticket>/` and sanitized results in the
tracked ticket and `client-testing.md`. Never fabricate passes or treat attempted
input as observed success. Raw client logs/captures are private by default.

## Private vanilla inspection

`prepare_vanilla.py` checks the pinned jar hash and extracts it to ignored
`research/vanilla-bundle/`. `java_tool.py` compiles our original small harnesses to
ignored `research/java-tools/`. For focused inspection use `javap -c -p`, with
dumps under `research/disassembly/`. If bytecode is insufficient, keep a pinned,
checksum verified decompiler under `research/tools/` and output under
`research/decompiled/`. Record tool version, input hash, classes/methods and the
behavioral conclusion. These operations do not start vanilla or accept its EULA;
a differential vanilla server is a separate operation.

Do not publish Mojang `.java`, assets, jars, extracted reports, upstream checkouts,
local helpers or account information. Our public-tree audit checks tracked and
candidate staged paths and rejects private reference directories and packaged
binaries, including force-staged ignored files. Also review the staged diff.

## Measurement

Optimize measured bottlenecks. Record hardware, schedulers, view distance,
gameplay/tick work, density, elapsed time, latency, disconnects, memory and revision.
Compare implementations only with matched feature coverage. Independent regions
do not prove boundary correctness. Consider native acceleration or clustering
only after profiling and a defined consistency/failure model. Keep unrun checks,
pending features and deliberate deviations explicit.
