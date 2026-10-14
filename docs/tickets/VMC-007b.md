# VMC-007b — Connection-owned encrypted login and transport

Status: Planned — next implementation slice. Updated: October 14, 2026.
Depends on VMC-007a's automated-verified crypto/codec checkpoint. Online identity
verification remains VMC-007c; an encrypted offline connection is not authenticated.

## Scope and acceptance

Wire native key exchange and continuous encryption into the existing TCP owner.
Preserve default plaintext/offline preview until online authentication is ready.
An explicit encryption option may use the native hello authenticate=false flag
to exercise encrypted offline transport with the unmodified client; never present
that as verified online identity. VMC-007c must require encryption for online mode.

- Supervise one immutable server key pair and a bounded crypto job pool. Generate
  keys off socket/tick owners. Each pending connection admits one fenced job and
  keeps a bounded raw tail while awaiting its result; deadlines and late results
  cannot grant a lease or change another session.
- Explicit login phases/challenge consumption reject unsolicited/duplicate keys,
  malformed responses and stale jobs. Allocate a player lease/publish identity
  only after required transport/auth gates. Keep failures isolated to that peer.
- Handle a plaintext key response and encrypted tail in one TCP read, fragmented
  response/ciphertext and continuous IV state across framing/compression/login/
  configuration/play. Cipher contexts are created and advanced by their socket
  owner. Batch encrypted output and respect byte/rate/mailbox/write limits.
- Retain existing offline login, UUID fencing and save/recovery semantics. Do not
  log private keys or shared secrets. Define timeout/cancellation/key-owner failure
  behavior, and never retry a socket write by rewinding the cipher.
- Meaningful TCP/native regressions for positive flows, coalescing, fragmentation,
  invalid/replayed responses, capacity/deadline isolation and compressed play;
  format, full tests, release, full Mojang oracle, public audit and exact diff pass.

Actual Minecraft 26.3 / CUA: encrypted offline login with the native authenticate
flag false, chunk rendering, /stats, actual inventory input, reconnect and full
restart; verify continuous encrypted transport and unchanged saved player state.
Restore normal configuration. Validate VMC-007a's integrated client gate together
with this slice, retaining the absence of online identity verification explicitly.

## References

Pinned Mojang Crypt/login packets and ServerLoginPacketListenerImpl; actual
client hello handler and encryption pipeline as needed. Pumpkin/SteelMC reference
phase transitions inform boundaries; original OTP ownership/fencing design governs
implementation. Private jars, bytecode, keys and fixture traffic remain ignored.

## Verification

Pending implementation and all checks/client scenarios.
