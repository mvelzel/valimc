# VMC-007c — Verified online identities

Status: Partially implemented — real online identities validated. Updated: October 14, 2026.

VMC-007a/b provide encrypted transport. Online mode must send authenticate=true,
verify the native signed server digest through Mojang HTTPS, then admit the returned
UUID and properties. Never fall back to offline identities on any failure. Keep
offline saves separate from online UUIDs; do not silently migrate player files.

- VMC-007c1 (Done): bounded verified HTTPS lookup and native profile/property decoding.
- VMC-007c2 (Done): bounded monitored authentication jobs, explicit connection phases,
  online configuration, authenticated login/player-info properties, fencing and
  deadline tests, native TCP codecs and actual licensed-client join/reconnect.
- VMC-007c3 (Done): service-discovery refresh and complete operational/failure controls
  as required by the pinned 26.3 implementation; retain narrower coverage explicitly.

Each slice records a real-client scenario first and preserves the user's fresh
world/player state. Full online testing uses a separate ignored world because
authenticated UUIDs intentionally differ from offline UUIDs. User account tokens
remain in the official client; the server needs only username and server digest.
Signed chat/profile-key handling remains a separate compatibility slice.

Discovery routing/refresh and real-account admission are validated. Signed chat,
proxy-IP policy, duplicate-session replacement and remaining authentication
configuration/administration keep the parent subsystem partial.
