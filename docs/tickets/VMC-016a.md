# VMC-016a — Owned abilities and persistent creative flight

Status: Done — creative flight validated, local. Updated: October 14, 2026.
Depends on VMC-003a accepted-state preservation and VMC-005c/019b journals.

## Scope and acceptance

Replace the preview's fixed ability packet and ignored flight requests with
socket-owned ability state. Establish vanilla's four-mode ability matrix as a
pure function; this slice still admits creative players only. Full mode changes,
spectator visibility, adventure component predicates, survival mining/damage and
administration remain VMC-016b and the corresponding gameplay tickets.

- Check native GameType transitions, speed preservation, both ability codecs and
  the listener's permission rule. Only bit 1 of client input controls flight;
  other bits never grant permissions or change speeds.
- Accept flight only when the owner permits it. Publish accepted state without
  a global gameplay call. Match vanilla's no-echo behavior for valid input.
  Reject malformed body lengths through the existing isolated failure boundary.
- Persist the flight boolean with pose/inventory in a bounded checksummed record.
  Read versions 1/2/3 without granting permissions from disk. Preserve flight and
  source sequence/outbox across preparation, replay and disconnected cleanup.
  A late inventory completion must not roll back newer flight input.
- Test native matrix/codecs, forged flags, denied flight, malformed frames,
  reconnect, save/recovery boundaries and state migration. Pass format, all tests,
  production release, full native oracle, audit and exact diff review.

Actual Minecraft 26.3 / CUA: capture fresh preview context; use actual double-Space
to enter flight, ascend, then reconnect and fully restart while flying. Observe
hovering plus owner state, inventory/selection/source sequence preservation and
/stats response. Toggle flight off through actual input and reconnect again.
Restore the original flight/pose without changing user items or world clocks.
Malformed/permission cases use independent TCP clients; fixture-set flight cannot
replace actual keyboard toggles.

## References

Pinned Mojang 26.3 jar SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`GameType.updatePlayerAbilities`, `Abilities`, both PlayerAbilitiesPacket codecs,
and `ServerGamePacketListenerImpl.handlePlayerAbilities`. The listener assigns
`requestedFlying && mayfly`; creative preserves current flight, spectator enables
it, survival/adventure clear it. May-build is not part of the wire flags.

SteelMC's pinned `steel-core/src/player/abilities.rs` separates permissions from
client flight requests, but its denial resynchronization differs from vanilla's
no-echo listener. Adopt ownership separation without locks or that behavioral
change. Pumpkin's pinned `crates/pumpkin-core/src/net/java/play/player_abilities.rs`
also separates requested flight from permission, with its own plugin cancellation
and fall-distance hooks. Fall distance remains VMC-015. Native semantics remain
authoritative; reference code stays ignored. No Rust locks or plugin hooks are
introduced into the connection owner.

## Verification

October 14: format, all **326 tests** (seed 959731), production release and full
Mojang oracle pass. Nine new tests cover matrix/speeds, all client bytes,
permission denial/no echoes, checksummed invalid records, old-state migration,
ordinary/creative journals, accepted input before malformed input, reconnect,
late transfer completion and disconnected pending recovery. Existing migration
and exact-file fixtures now distinguish current version 4 from legacy versions.
The empty current record is **152 bytes**; v1/v2/v3 remain readable. Permissions,
menu authority and drag state remain excluded from persistence.

The original native harness invokes actual `GameType.updatePlayerAbilities` for
**64** transitions and encodes/decodes their exact ability bytes. It decodes all
**256** client bytes and compares **512** permission-gated outcomes. The native TCP
suite checks actual request codecs and no unsolicited ability echoes over both
plaintext and continuous AES-CFB8 transport. Private logs:
`.local/vmc016a-{tests,release,oracle}.log`; private bytecode stays under
`research/disassembly/VMC016-*`. No gameplay server is launched by the probes.

Actual **Minecraft 26.3**, `ValiMC computer-use test`, localhost production release
starting **14:37:07 CEST**: CUA generated two 40 ms Space presses, and owner flight
became true. A held 600 ms Space ascended to y **70.61186044467989**. The player
hovered while `/stats` responded. Normal Disconnect/rejoin retained exact pose,
flight, inventory and selection. Complete server restart at **14:39:57 CEST** and
actual rejoin retained that same state. Another actual double-Space disabled
flight; the client fell to y **64** and its original exact pose. Final Disconnect/
rejoin retained flight off and the original world view.

Cleanup preserved every supported inventory value, selected slot **0**, source
sequence **54** and nil outbox. No fixture-set flight, item/world edits, snapshot
rollback or clock/weather resets were used. Fresh contexts:
`/tmp/valimc-vmc016a-{preview,flight}.etf`. The client remains paused in the preview.
`.local/client-tests/VMC-016a/latest.log` has zero ERROR/Exception entries; the
release logged no validation errors.

Computer use initially rejected the bundle ID with `cgWindowNotFound`; the exact
generated app path restored keyboard/screenshots. Coordinate clicks then returned
`noWindowsAvailable`, so observed Tab/Shift+Tab focus and Return performed menu
navigation. This ticket's actual keyboard gates pass; older sustained/middle
mouse gates are unaffected and remain pending. No mode transition, survival
simulation, collision/fall enforcement or spectator interaction parity is claimed.

Commit subject: `Own player abilities and persist permission-gated creative flight`.
