# VMC-007a — Native encryption primitives and login codecs

Status: Done — integrated encrypted client validated, local.
Updated: October 14, 2026.
Parent VMC-007 requires encrypted transport and verified online identities;
this foundation alone does not provide either to a running connection.

## Scope and acceptance

Implement original bounded primitives using OTP crypto: native RSA key/public
encoding, encrypted secret/challenge verification, login hello/key codecs,
signed SHA-1 session hash and independent AES-128-CFB8 stream directions.

- Match pinned Mojang Crypt and login codecs with independent native probes,
  including cross-language RSA/DER, signed hashes and fragmented AES streams.
- Generate the native 1024-bit RSA key with exponent 65537 and a four-byte random
  challenge. Key generation belongs at startup or in bounded cold-path jobs;
  it must not run inside a sensitive socket/tick owner.
- Reject invalid/truncated/oversized key packets, failed padding, wrong challenge
  or non-16-byte decrypted secrets with one opaque error. Validate before use.
- Cipher resources mutate internally: each connection owns separate read/write
  contexts. Reject cross-process use and oversized input before advancing state;
  never fork/replay a context or reset the IV at packet/compression boundaries.
- Use secret bytes as IV, preserve the native signed lowercase hexadecimal hash
  and use an empty server ID. No production keys/secrets in fixture logs.
- Pass meaningful regressions, format, full suite, release, native oracle and
  public-tree audit. Keep generated keys/fixtures/bytecode private.

Actual Minecraft 26.3 / CUA gate after VMC-007b transport integration: perform an
encrypted login, render chunks, execute /stats, perform inventory input, reconnect
and confirm the continuous cipher survives login/compression/play boundaries.
The native oracle cannot replace that gate. Until integration exists, keep this
checkpoint unverified/unpushed; the current server remains an offline preview.

## Follow-on slices and ownership

VMC-007b wires the bounded key exchange and continuous cipher into connection
framing/writes, including plaintext-response plus encrypted-tail coalescing,
phase/replay rejection and bounded asynchronous crypto jobs. VMC-007c adds HTTPS
session verification, authenticated UUID/properties, configuration and failure
limits before a player lease or publication is granted. Define transport/auth
deadlines and fencing before enabling online mode; no global gameplay process.

## References

Mojang 26.3 jar SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`Crypt`, `ClientboundHelloPacket`, `ServerboundKeyPacket`; private bytecode in
`research/disassembly/VMC007-crypto.txt`. The installed OTP 29.1.1 crypto supports
RSA and AES-CFB8. Early no-start Mix probes appeared to lack public_key/SSL/inets;
VMC-007c1 confirmed they are installed and were pruned because they were undeclared.
Declaring SSL resolves that HTTPS prerequisite. This crypto foundation itself
needs no new dependency.
See [OTP crypto documentation](https://www.erlang.org/doc/apps/crypto/crypto.html).

Pumpkin `b0c48b2d7688`, Java `login/encryption_response.rs`, consumes its pending
token before verification and enables encryption before asynchronous profile
authentication. SteelMC `f6fb4e49778c`, `steel-login/src/handlers/login.rs`, makes
reader/writer encryption transitions explicit. These reinforce the phase/fencing
boundary for VMC-007b; their mutex/reader-task arrangements are not copied into
the BEAM design. Mojang defines all crypto/codec behavior. Own public DER encoding
is limited to generated keys and is verified by Mojang's X.509 decoder; it does
not introduce an untrusted ASN.1 parser or another runtime dependency.

## Verification

October 14: format, **279 tests** (seed 480677), production release, full Mojang oracle and
public-tree/diff checks pass. Private logs:
`.local/vmc007a-{tests,release,oracle}.log`. Four new tests cover native key/challenge
shape, redacted key inspection, padding/nonce/secret/framing failures,
noncanonical five-byte VarInt lengths, continuous fragmentation, independent
directions, cross-owner rejection and rejection before cipher advancement.

The original native probe validates **32** synthetic cases with actual Mojang
`Crypt`, `ClientboundHelloPacket` and `ServerboundKeyPacket`: public DER canonical
round trips, both authenticate flags, signed hash equality, RSA responses and
AES streams of 0–8192 bytes including non-block boundaries and zero/FF keys.
Mojang decrypts Elixir streams in irregular fragments; Elixir decrypts Mojang
streams byte by byte and verifies its RSA response. Generated private keys and
fixtures stay in temporary ignored paths; the full oracle removes its temporary
directory. It starts no vanilla gameplay world/server and accepts no EULA.

October 14: VMC-007b integrated these primitives into socket ownership and passed
287 tests, release and full native plaintext/encrypted TCP suites. Its actual
Minecraft 26.3 CUA scenario passed encrypted login, rendering, `/stats`, hotbar/
inventory input, reconnect and full restart with saved state retained. See
[VMC-007b](VMC-007b.md) for actions, evidence and cleanup. This completes the
foundation's client gate. Default preview remains plaintext/offline; online
authentication still requires VMC-007c.
