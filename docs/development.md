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
6. Hand actual Minecraft 26.3 validation to one dedicated client-testing subagent.
   Give it the ticket/scenarios, exact release/checkpoint, dataset and evidence
   paths. It owns computer use, exercises the changed behavior, inspects screenshots
   and client/server logs, and tests reconnect/restart when relevant. Coordinate
   restarts/fixtures and keep its release unchanged. The primary continues the next
   implementable slice and automated checks while retaining the pending GUI queue.
7. Record evidence and limitations, update roadmap/compatibility notes, review
   the diff and public-tree audit, amend the unpushed ticket checkpoint if needed,
   and push `main` after required client checks pass. An explicit user request
   to publish checkpoints can override withholding a push; it does not turn
   pending tests into passes. The October 13 request to push all work includes
   VMC-005b2a's automated-verified checkpoint with its gesture gate still pending.
   Done means every required check and client scenario passed. A failed push
   remains an unpublished local checkpoint until a normal retry succeeds.

Client testing is always delegated, as requested October 15, 2026. Use one UI
driver to avoid interference. Review the tester's evidence before closing a
ticket; failures become explicit fix/retest work. Keep ticket commits separable
so publishing validated work does not publish later unvalidated checkpoints.

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
Collision checks regenerate cached geometry and compare native voxel clipping;
actual contact fixtures and evidence limits are in [VMC-014a](tickets/VMC-014a.md)
and [VMC-014b1](tickets/VMC-014b1.md). [VMC-014b2](tickets/VMC-014b2.md) checks
scaffolding contexts and exact clipping against native methods, plus actual
landing/descent contacts in the graphical client.
The [collector differential](tickets/VMC-014b6c2.md) compares native `BlockCollisions`
order/geometry; separate regressions check retained input fences and explicit errors.
The [step differential](tickets/VMC-014c2.md) invokes native `Entity.collide`
through controlled collider providers; client checks separately compare contacts.
Item checks generate nine stack fixtures with Mojang's codecs, decode and
cross-convert them in Elixir, then ask Mojang to decode the resulting bytes and
compare semantic equality in both ordinary and delimited formats. A focused
raw-patch identity harness compares 18,430 pairs against Mojang's actual decoder
and equality method across every item prototype, default additions, removals,
glint and NBT numeric/list equality. The oracle re-extracts and compares prototype
presence/supported defaults with public facts. Semantic keys must not alter raw
stack encoding or historical transfer receipt digests; regression tests retain
exact-intent retries across serialization.
The text harness generates 121 raw native cases and 5,050 equality pairs, including
style presence, color/font aliases, translations, mixed-list wrappers, numeric
arguments and non-finite numeric styles. It checks lore counts 0/1/256/257 with
Mojang, then Mojang decodes 100 Elixir name/lore cases in both stack formats.
Text keys are separate from retained declarations and exact transfer digests.
The enchantment harness probes all 43 negotiated holder IDs, 193 decode cases and
16,471 equality pairs. Mojang decodes 181 Elixir maps/stacks in both formats.
Network zero-level presence, overwritten duplicate levels and empty defaults are
explicit cases; saved-data level constraints are distinct. A 1,024 raw-entry cap
bounds noncanonical repeated input; unique core-pack maps have at most 43 entries.
The TCP oracle separately sends active Unbreaking III and stored Sharpness V.
The tooltip harness probes all 122 component IDs, 264 raw cases, shows results and
32,896 native equality pairs; Mojang decodes 256 Elixir values/stacks in both
formats. Sets ignore duplicate/order differences, but membership still matters
under hide-all. A shared immutable component index prepares default keys without
an ItemTypes/value-codec compilation cycle. The 1,024 raw-entry guard also bounds
noncanonical repeated tooltip IDs. Actual Minecraft E checks visible, selective,
whole-hide and reset rendering while retaining names/lore/enchantments/glint.
Actual close checks equal/default merging and differing control identity; Q/Ctrl+Q
checks exact saved item records, then reconnect/full restart restores controls
without reseeding. Unknown-ID/truncation owner fixtures must preserve accepted
state; TCP tests separately verify peer isolation. Cleanup retains advanced source
counters/receipts and restores only fixture inventory/pose/entities.
The world-clock oracle invokes Mojang's actual clock tick arithmetic for 3,600
fraction/rate/pause/global-stop/long-boundary cases and decodes every Elixir network
value. The full native TCP oracle checks both registered holders, fresh login
and periodic 20-tick updates. ExUnit additionally stalls the linked writer, checks
one immutable pending save/newer dirty state, injects stale timers/replies, and
reloads a physical-commit/withheld-ack fixture without writing older memory over
it. Actual Minecraft uses explicit trusted host controls to observe day/night/day,
continued commands, independent pause, reconnect/full restart and resumed clocks.
Keep fixtures/logs private, restore normal controls and retain game-time progress.

The weather oracle invokes the actual private ServerLevel weather method through
an isolated constructor-free probe with captured packet effects; no gameplay
server/world starts. Its 480 traces cover 50,400 ticks of timer/flag/random/intensity
state and exact event ordering. Tests add clock-record migration, native load
preparation, host controls, observer coalescing/bounds and actual TCP transitions.
Actual Minecraft checks rain/storm/clear and intermediate intensity, automatic
expiration, frozen timers with continued ramps/commands, reconnect/full restart
and normal-control cleanup. UI-synchronized host fixtures may watch a real hotbar
selection to capture a short transition; that is explicit fixture setup, not an
implemented weather command. Keep their context and client logs private.

A focused
inventory behavior harness also invokes Mojang's actual menu methods to verify
collect ordering, direction, triggers, caps, ordinary-slot component preservation,
creative clone/fill permissions, start-time fill authorization and the actual
inventory-return method's selected/offhand/storage order and overflow effects.
It uses a constructor-free test player only within that development harness.
The return harness captures requested drops without simulating item entities.
World/player lifecycle and equipment locks require their own tests. Temporary
fixtures are not committed. Mojang also decodes Elixir text containing NUL and
supplementary Unicode. TCP scenarios then exercise slot updates/corrections.

The difficulty probe checks the actual dedicated-server default, all 64 native
lock/force combinations and all eight level/lock packet bodies. TCP checks verify
login, two observers, retained reconnect state, rejected peer mutation and no
unchanged-state packet repetition. Actual Minecraft World Options checks all four
labels and both lock icons after reopening the screen, ignored non-forced changes,
forced override, continued commands, reconnect and full restart. Use trusted host
fixtures, restore the original authoritative setting and retain player state.
Those controls do not establish operator permissions or survival effects.

The encryption probe passes synthetic public keys/hello bodies, hashes and AES
streams to Mojang's actual crypto/login classes. Mojang returns RSA key-response
bodies for Elixir verification. Key fixtures remain temporary; private key
inspection is redacted. Cipher resources mutate in place and must stay with their
socket owner; reject cross-process/oversize calls before advancement. The full TCP
oracle now runs in separate fresh worlds for plaintext and encrypted transport,
using Mojang's actual key and stream classes. Read exact positive-length frame
bodies: JDK 25 CipherInputStream may block on readNBytes' zero-length probe.
TCP tests cover coalesced/fragmented transitions, pool limits, replay/deadline
fencing and infrastructure failure. Actual CUA validation enables
`VALIMC_ENCRYPTION=true`, checks rendering, `/stats`, hotbar/inventory input,
reconnect and full restart, then restores normal configuration. Capture fresh
player state first; compare inventory contents/selection without the session-local
menu state ID. Never send raw fixture packets from an RPC process into an encrypted
socket: trusted fixture writes must advance the cipher inside its socket owner.
These transport checks pass in VMC-007b; authenticated identities remain VMC-007c.

The session-profile probe uses authlib's native ObjectMapper/response/GameProfile
on synthetic data, then compares UUID, requested name and every opaque property
value/signature. Runtime verified HTTPS uses worker-owned passive SSL and OTP's
HTTP header parser. Regression fixtures generate in-memory CA/leaf certificates
and exercise actual TLS success before testing framing/size failure. Check all
three body framings while reading: OTP httpc's close-delimited path does not
enforce its body option before accumulation. A killed worker must close its TLS
socket. Foundation client smoke verifies the release includes working SSL and
retains the ordinary preview; it cannot establish authenticated online login.

Online-mode validation uses `VALIMC_ONLINE_MODE=true` and a separate ignored
world. Capture fresh preview state first; authenticated and offline UUID saves
must remain separate. Verify the existing official client joins through the real
service, then inventory/selection, reconnect, restart and an explicit trusted
outage rejection with no player lease. Restore the real service and normal
preview configuration/world. Synthetic controlled providers establish fencing,
deadlines and failure isolation; they do not authenticate a real account. Native
profile probes also decode login/player-info bodies with exact values/signatures.

Discovery probes run native authlib routing/refresh against synthetic documents and
a recording executor, without external requests or real-day waits. Unit tests cover
startup subscriptions, late results, cached/unavailable publications and isolated
owner failure. Real-client validation must distinguish retained cached routing
after refresh failure from a successful offline document, which rejects new joins.
Verify an admitted player keeps responding after owner restart, then cold-start
real discovery again and restore the fresh preview state. Reference manifests and
logs remain ignored; the codec oracle explicitly disables online mode so inherited
environment settings cannot accidentally trigger account verification.

Mode initialization probes construct the pinned native dimension registry and compare
all 20 current/optional-previous login bodies, then decode Elixir player-info modes.
Unknown network IDs have native survival fallback; saved IDs are validated strictly.
Version 5 journals retain mode identity, while permissions are rederived at admission.
All four actual-client UI checks and full restart are required; record permission
mouse checks separately when CUA cannot emit them. Keep live transition/collision,
spectator peer visibility and non-creative gameplay dependencies explicit.

Interaction-range probes re-extract builtin attribute facts, compare mode-selected
native packet bodies and decode the Elixir output. Geometry cases use Mojang's
actual block-box distance, strict reach equality and translated float32 hit bounds,
including NaN/infinity. Remote rejected TCP actions must not allocate regions.
Actual-client tests distinguish five-block creative targeting from 4.5-block
non-creative targeting, then verify reconnect/restart. The current standing eye
height is explicit; other poses and general attributes require separate coverage.

Ability probes invoke native GameType transitions and both ability codecs for
all modes/initial flags, including speed preservation and all 256 client bytes.
Only the flying bit may change under the owner permission. TCP tests also cover
no echoes, denial, malformed-following-accepted input, newer flight during transfer
completion and pending-disconnect recovery. Version 4 saves flight only; disk
never grants ability permissions. Actual double-Space must generate both toggles,
then hovering/reconnect/full restart and cleanup retain exact player state.

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
Disconnected cursor/grid cleanup now drops whole stacks through the durable
journal, even with free storage. Tests distinguish raw administrative fixtures
from live session termination, and old/unclean carried/grid saves are disposed
before login publishes inventory. Verify offline delivery before reconnect,
closing-writer takeover, exact pinned UUIDs after recovery and unchanged main/
offhand contents. Fixtures cannot establish actual mouse pickup/drag behavior.

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

VMC-005b2d2a integrates connected close overflow as a conserved multi-item plan.
Tests stall prepare/destination publication, gate repeated close/click/swap, admit
after normal-save acknowledgment, preserve disabled/failed storage and recover
disconnects. A destination with only four free item slots must reject all five
remainders; releasing capacity permits the pinned retry without partial publication.
Mojang's actual return method and official TCP codecs verify the partial merge,
five remainder identities/damage and cleared cursor/grid. Actual E/Escape close
with prepared fixture contents is the changed action; original mouse pickup stays
a separate parent gate. Test repeat/reconnect/restart, disabled-source correction,
repair/retry and stalled close, then clean UUIDs without regressing counters/receipts.

VMC-019b3d1 adds a separate trusted-owner creation source API. Tests retain all
owned contents, keep ordinary conservation mandatory, reject unauthorized/foreign/
stale/invalid/disabled/pending requests, fence failed writes, recover lost replies,
and reconcile the creation automatically at login. The graphical scenario uses
an offline source API fixture, then actual reconnect/restart observes retained
inventory plus the one pinned item. Remove/retry must stay removed; cleanup
retains counters/receipts. This is source/recovery evidence. Actual creative drop
controls, paired creative slot writes, and tick throttling remain VMC-019b3d2.

VMC-019b3d2 adds connected negative-slot creation and a bounded connection-local
FIFO for following creative commands. Tests cover paired frame order, throttle,
count/byte rejection, source/destination stalls, normal checkpoint independence,
permission revocation and committed-only recovery after disconnect. Mojang's
actual TickThrottler and official creative packet codecs validate independent
boundaries. Actual creative-screen Q/whole-stack or outside drop must produce a
creation request and its separate source-slot update; in-world Q uses a different
path and cannot pass this gate. Deferred commands are unacknowledged input, not a
persistent journal. Clean only pinned UUIDs, retain source counters/receipts, and
record controls that could not be emitted instead of substituting a fixture.

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

If the test bundle ID returns `cgWindowNotFound`, retry the exact generated
`.local/Minecraft Client.app` path through `cua.getApp`. Refresh the binding after
session changes. Keyboard focus (Tab/Shift+Tab, inspect, Return) can operate menus
when coordinate clicks fail; record that limitation and keep mouse gates pending.

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
tracked ticket and `client-testing.md`.

The user authorized treating the development Minecraft client and test world as
disposable fixtures on October 14, 2026. Freely change or reset builds, inventory,
pose and selection for validation, including changes from their experimentation.
Account/launcher credentials and unrelated resources are outside this permission.
Within one test dataset, retain source counters/outboxes and destination receipts
when checking recovery or conservation. A fresh test may reset the complete
dataset; restoring only a pre-transfer source after destination commit would
invalidate the evidence. Earlier instructions to preserve user builds/items are
superseded by this authorization.

Never fabricate passes or treat attempted
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
