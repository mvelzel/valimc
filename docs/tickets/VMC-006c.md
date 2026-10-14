# VMC-006c — Persistent world difficulty and client synchronization

Status: Done — difficulty state validated, local. Updated: October 14, 2026.
Depends on VMC-006a/b environment ownership, immutable publications and fenced I/O.

## Scope and acceptance

Replace implicit client-default Normal difficulty with authoritative native Easy /
unlocked world state. Persist all four native difficulty levels and the lock flag.
Trusted host changes follow vanilla's lock/force behavior; client administration
requires the later permissions ticket. Hardcore, regional difficulty, damage,
hunger and spawning effects remain separate gameplay work.

- Establish IDs/defaults, packet codec and lock/force behavior from the pinned
  Mojang 26.3 implementation and an isolated native probe.
- Own difficulty with the existing environment state. Publish cached immutable
  packets in ETS; sessions sample changes in their existing replication batch.
  No player fan-out messages or global gameplay calls are added.
- Send current difficulty/lock at login and after changes; unchanged observations
  produce no extra difficulty packets. An unprivileged client cannot mutate it.
- Extend the bounded checksummed record; versions 1/2 migrate without losing
  clocks/weather/random history. Invalid IDs/flags, truncation and bad checksums
  reject. Retain existing writer/fencing/failure boundaries.
- Pass meaningful state/codec/migration/TCP tests, format, full suite, release,
  full Mojang oracle, public-tree audit and exact diff review.

Actual Minecraft 26.3 / CUA: inspect World Options difficulty text and lock icon
for Peaceful, Easy, Normal and Hard via explicit trusted host fixture controls.
Check locked/unlocked display, ignored non-forced change and forced override,
continued /stats response, reconnect and full restart with Hard/locked retained.
Restore the original setting, leave inventory/pose/source counters intact and
inspect client/server logs. These fixtures do not validate an operator command,
hardcore or difficulty-dependent gameplay.

## References

Pinned Mojang jar SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`Difficulty`, `ClientboundChangeDifficultyPacket`, `MinecraftServer.setDifficulty`,
`setDifficultyLocked`, `sendDifficultyUpdate`, `DifficultyCommand`,
`DedicatedServerProperties` and `ServerGamePacketListenerImpl` permission checks.
Private bytecode/probes stay under ignored research paths. Dedicated-server
default is Easy; lock prevents non-forced changes, while a trusted forced
change can override it. Hardcore forces Hard and is outside this slice.

Architectural references at the revisions in `research/sources.lock.json`:
Pumpkin `b0c48b2d7688bbfa09956adf530b8bc56dcc0c56`, its Java difficulty handler;
SteelMC `f6fb4e49778ccffc5c13c3b87c1c2600dd9435aa`, difficulty command and packet.
Both separate authorization from world mutation; Steel's domain/world routing is
not copied into the BEAM owner design. Vanilla remains the behavior authority.
No reference source is included in the runtime or public tree.

## Verification

October 14: format, all **275 tests** (seed 266521), production release, full Mojang
oracle and public-tree audit pass. Private logs:
`.local/vmc006c-{tests,release,oracle}.log`. The native probe instantiates only
constructor-free server/player-list test objects, invokes actual lock/force
methods for **64** cases, checks all **8** codec bodies and reads the actual
dedicated-properties default. No gameplay server/world is launched. The default
is **Easy**, correcting the previous client's implicit Normal display.

Five tests cover controls/invalid input, cached packet reuse, checksum-valid
invalid IDs/flags/truncation, version-2 migration and physical owner reload,
two actual TCP observers, reconnect, ignored unprivileged peer mutation and no
unchanged-state difficulty packets. Existing version-1/weather and stalled-writer
failure/fencing tests continue passing. The record is now **113 bytes**, version 3;
versions 1/2 remain readable. An incidental existing inventory-test cleanup race
was fixed: a normally exiting writer needs no resume; unexpected failures still
propagate and gameplay assertions are unchanged.

Actual **Minecraft 26.3**, `ValiMC computer-use test`,
`local.valimc.minecraft-client`, localhost release starting **09:47:52 CEST**:
CUA inspected native World Options Easy/unlocked, Peaceful/unlocked,
Normal/locked and Hard/locked. Screens were reopened to refresh their local
draft. A non-forced Peaceful change while Normal was locked retained Normal;
forced Hard retained the lock. `/stats` responded normally. Difficulty controls
were read-only for the unprivileged client. All setup changes used trusted host
controls, not client difficulty commands.

Normal disconnect/reconnect retained Hard/locked. A complete production restart
at **09:51:19 CEST** restored the exact state; CUA rejoined and observed the same
label/closed lock. At **09:52:45 CEST** cleanup restored the original authoritative
Easy/unlocked setting, flushed it and verified the player's joined pose/inventory
were unchanged. Source sequence **29** and nil outbox remain; no fixture items or
player/world edits were used. CUA observed Easy/open lock after cleanup and left
the client paused. Private context: `/tmp/valimc-vmc006c-context.etf`.
`.local/client-tests/VMC-006c/latest.log` has zero ERROR/DecoderException entries;
the production server logged no validation error.

A final harmless Cancel-button coordinate click succeeded, so older mouse-input
gates can now be retried. This does not itself pass those inventory scenarios.
Hardcore, regional difficulty, difficulty-dependent gameplay and client
administration remain incomplete; VMC-006 is only partially implemented.
