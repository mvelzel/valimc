# VMC-003a — Retain accepted state across a failed TCP batch

Status: Done
Note: Done — local, unpushed. Updated: October 13, 2026. Follows VMC-003.

## Scope and acceptance

The current outer exception guard can return the state from before an entire TCP
batch. If that batch completes configuration, confirms teleport, accepts a new
pose and then fails, termination sees the old configuration phase and skips the
final save. Fix this callback boundary before relying on it for more player state.

- A deterministic callback batch crossing configuration to play preserves every
  earlier successful packet when a later frame is rejected or raises a parsing
  exception. Reconnect restores the accepted XYZ/yaw/pitch.
- Retain session ownership and the existing 64-packet drain budget. Frame parsing
  and packet handling are guarded individually; no global recovery coordinator,
  extra ETS authority, or growing nested exception stack is introduced.
- Explicit disconnects carry their current state. Unexpected failures fall back
  to the state immediately before the failing packet, not before earlier packets.
- Failed configuration without accepted play state does not overwrite player data.
- Run the complete suite/oracle/release/audit. Actual-client scenario: move/rotate,
  inject an intentional later malformed frame through the local packet handler,
  observe disconnect, rejoin and verify the accepted pose; check `/stats` and logs.

## Evidence and design

This is an Elixir callback/termination boundary, identified by reviewing
`Connection.guard_connection/consume/terminate`. Vanilla pose storage semantics
remain those pinned in VMC-003. Test helpers may stop before finish-configuration;
the precise batch is delivered to a real configured session as one TCP callback
message so transport segmentation cannot accidentally hide the regression.
Full independent Mojang TCP checks remain part of verification.

## Verification and checkpoint

The new regression failed before the repair: the phase-transition batch left no
pose file. After repair it passes for both frame rejection and an unexpected
payload parsing exception. A separate regression confirms a failed configuration
preserves an existing valid save byte-for-byte.

Each frame/handler now has its own exception boundary; recursion occurs after
leaving that guard. Explicit disconnects carry current state. The existing drain,
rate limits, owner publications and leased writer lifecycle remain in use.
All 60 ExUnit tests, formatting, production release, nine Mojang stack cases,
Unicode text and the full independent TCP oracle pass. Audit/self-tests and
exact-diff checks pass. Private build/oracle logs are under `/tmp/`.

Actual Minecraft 26.3 with the final isolated input adapter: keyboard movement
and mouse rotation produced XYZ -2.865 / 64.000 / -0.211, yaw 104.7 / pitch 47.8.
A local protocol fixture then moved X by -0.25 and appended a bad frame in the
same callback. The game displayed “Malformed packet.” Rejoin rendered the world
and F3 showed -3.115 / 64.000 / -0.211 with unchanged angles. A read-only check
confirmed all five restored fields exactly match the accepted fixture. `/stats`
responded with one player, four regions, ten schedulers and 77 MiB. The raw log
at `.local/client-tests/VMC-003a/latest.log` has no protocol/codec errors.
Graphical recovery tests the play-stage batch; deterministic connection tests
cover the precise configuration-to-play boundary. Fixture setup is distinguished
from actual computer-use movement/rotation/actions. No inventory persistence or
crash-durability claim is added.

Subject: `VMC-003a: retain accepted state when a later packet fails`.
No push while the remaining client gates are queued. VMC-003's pending failure
boundary is resolved. Next: VMC-005b2a quick-craft.
