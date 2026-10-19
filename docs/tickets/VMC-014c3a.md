# VMC-014c3a — Player input and shared flags

Status: Done
Note: Done — validated. October 15, 2026. Depends on existing connection replication.

Retain the seven native input booleans and replicate Shift/sprint flags. These
packets were previously ignored. This slice supplies intent for later movement;
pose selection, dimensions, sprint attributes and authoritative physics remain.

Acceptance:

- Match pinned input/command codecs, including ignored input bit 7, the seven
  current action ordinals, signed command data and exact payload consumption.
- Retain pre-load input; apply Shift/sprint only after `player_loaded` or the
  native 60-tick fallback. Loading does not replay earlier input/commands.
- Shift sets shared bit 1; sprint commands set bit 3 independently of the input
  sprint boolean. Valid unsupported actions remain inert in this preview.
- Each connection owns its input. Existing paced ETS observation coalesces flags
  for self/peers; spawn/re-entry/large teleport initialize metadata. Unchanged
  flags send no metadata; flags alone send no movement packet. Foreign command
  entity IDs cannot change another connection. Reconnect resets ephemeral input.
- Rejected frames preserve accepted state and isolate the offending connection.
  Pass format, full tests, production release, native suite and public audit.
- Actual 26.3/CUA: hold/release Shift+W and Control+W, observe input and shared
  flags during the held gestures, verify release, `/stats`, reconnect and a fresh
  client-log check. Capture peer metadata with a loopback observer if needed;
  distinguish packet evidence from graphical pose/physics authority.

Reference: Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`,
`Input.STREAM_CODEC`, `ServerboundPlayerInputPacket`,
`ServerboundPlayerCommandPacket.Action`, `ServerGamePacketListenerImpl` input,
command/load handlers, and `ServerEntity.sendDirtyEntityData` (tracking and self).
Private bytecode: `research/disassembly/VMC014c3-*`. Existing SteelMC/Pumpkin
research informs subsystem separation; native handlers define these semantics.

The preview's existing 50 ms publication tick drives the load fallback. It is not
yet an authoritative simulation clock. No new global coordinator, per-key process
or timer is needed. Collision-selected pose/eye height requires fit checks and
will be a separate ticket; Shift intent must not directly select a pose.

Implementation: immutable input state belongs to the socket owner. Validated
input/commands update its ETS observation; the existing publication interval
coalesces shared flags for self and peers. Eight-field peer views retain flags
alongside quantized movement. Metadata-only updates skip movement, and entity
recreation initializes flags even when unchanged. No input state is persisted.

Verification, October 15:

- Format, 439 tests, production release and full native suite pass. The new probe
  exercises 256 actual input decodes, 175 command cases, 65 native load-counter
  states and four actual entity flag setters/metadata encodings. Full plaintext
  and encrypted TCP runs decode self/peer transitions through Mojang's codecs.
- Regressions cover pre-load retention/no replay, timeout boundary, independent
  sprint intent, foreign IDs, unsupported actions, metadata-only/unchanged
  observations, late observers, large-teleport recreation, visibility re-entry,
  reconnect resets and malformed sender isolation.
- Primary's CUA checks at 06:35–06:38 CEST: actual Shift+W and Control+W holds
  produced buttons 33/flags 2 and buttons 65/flags 8, respectively, then zero on
  release. A loopback observer received flags 2,0,8,0 for the actual player.
  `/stats` responded. Observation fixtures supplied no player input.
- A pre-test client Vulkan semaphore timeout required restarting the Launcher
  and actual client; the fresh client rendered and joined the rebuilt release.
  Final reconnect/fresh-log gates were delegated to `minecraft_client_testing`.
  Private evidence: `.local/vmc014c3a-*`, `/tmp/vmc014c3a-watch.exs` and
  `.local/client-tests/VMC-014c3a/`.

- Dedicated tester, 09:04–09:09 CEST, keyboard only: localhost reconnect,
  rendered flat world, reset input/flags and `/stats` pass. Two client instances
  shared a log directory; the tester quit the first through CUA and repeated the
  checks on the remaining instance, giving an unambiguous fresh session.
  Repeated real Shift+W/Control+W holds produced 33/2 and 65/8, then 0/0 on
  release. The 09:07:32–09:08:27 session log has no ERROR, decoding exception or
  disconnect. Existing renderer post-effect warnings remain. Release module
  fingerprints match the tested checkpoint. Report/evidence were reviewed.

Exact diff/public audit pass. Packet and input observations do not establish
collision-selected pose or sprint speed attributes. No performance claim is made.
