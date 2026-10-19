# VMC-007b — Connection-owned encrypted login and transport

Status: Done
Note: Done — encrypted transport validated, local. Updated: October 14, 2026. Depends on VMC-007a's automated-verified crypto/codec checkpoint. Online identity verification remains VMC-007c; an encrypted offline connection is not authenticated.

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

October 14: format, **287 tests** (seed 422493), production release, full
Mojang oracle in both plaintext and encrypted modes, public-tree audit and exact
diff pass. Private logs: `.local/vmc007b-{tests,release,oracle}.log`.
Eight TCP regressions cover byte-fragmented keys, coalesced plaintext response/
encrypted compressed acknowledgment, independent peers, encrypted disconnect,
wrong/replayed/unsolicited keys, saturation, absolute deadlines, stale results,
abrupt owner death, stalled admission and key-infrastructure recovery. No player
lease is acquired before proof of the transport key. Admission is bounded to 32
jobs with a one-second call limit and five-second absolute deadline; owners monitor
workers, the pool monitors owners, and linked workers die with it. Existing
encrypted play stays responsive during a suspended admission service.

One startup key is published through protected ETS. Socket owners create and
advance independent AES-CFB8 directions; framing/compression never resets them.
Writes are bounded to 4 MiB before cipher advancement. Failed writes close the
peer rather than retrying an advanced stream. Key-service failure restarts dependent
connections/listener; region and player-writer infrastructure precedes that boundary.

Actual Minecraft 26.3, `ValiMC computer-use test`, October 14 at 12:21–12:25 CEST:
enabled `VALIMC_ENCRYPTION=true` on the existing private test world, joined via CUA,
observed saved terrain/logs/torches/cake and food inventory, selected hotbar slot 2,
submitted `/stats` and saw its response, restored slot 1 and opened inventory.
Verified the live play owner held its cipher and no pending key/recovery job.
Actual disconnect/rejoin and full release restart/rejoin both rendered the same
world and retained UUID, pose, all item patches/counts, selection and source sequence
34. Only the expected session-local menu state ID differed from the fresh captured
baseline. No older inventory fixtures were replayed. Restored default plaintext
configuration through another clean restart and rejoined successfully. Current
client log has no ERROR/Exception/DecoderException entries; private copy is
`.local/client-tests/VMC-007b/latest.log`. This also passes VMC-007a's client gate.

The native oracle uses Mojang Crypt and login codecs, then runs the entire existing
configuration/play suite over continuous encrypted streams. Its reader now stops
at exact positive-length frame boundaries: JDK 25 CipherInputStream can block on
the extra zero-length probe performed by readNBytes. This harness fix changes no
server behavior. The jar remains pinned at SHA-1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`.

Encrypted offline mode uses authenticate=false and retains offline UUIDs. Verified
online identities, skin properties and HTTPS session lookup remain VMC-007c.
