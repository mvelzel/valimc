# VMC-078b — Isolate native artifacts between build profiles

Status: Planned
Milestone: M3
Parent gate: [VMC-078](VMC-078.md), at its final validation/build boundary.

Rustler writes every profile to the source tree's `priv/native/valimc_nif.so`.
The current Mix app `priv` paths, including the oracle's private build, are
symlinks despite the project's `build_embedded` comment. Compiling production
in the main checkout can therefore replace a running check's parity library.
A cached profile can also reuse another profile's most recent source library.

The VMC-045a9 validation reproduced this: terrain's test-only NIF became
unavailable during a concurrent main-checkout production build. Its owning
validation tree was stopped, evidence retained, and the tested fast/parity
artifact copied into physical private check assets before restarting. The
active graphical client's separate frozen release was not involved.

Acceptance at the final M3 build boundary:

- Each compiled environment loads its own native artifact; production and
  parity variants cannot replace one another through the source-tree path.
  Cached compilations retain the artifact matching their code/features.
- Concurrent profiles do not share a mutable Cargo output filename for
  different feature sets. Reuse compiled dependencies where practical.
- The oracle's private assets remain stable across subsequent builds; replace
  the false `build_embedded` claim with the mechanism actually used.
- Verify profile switching and overlapping checks/builds with real parity
  calls and the production release, then run the milestone's full fixtures
  and suite once on the final implementation. This is local build work; no CI.

Keep this change at the final boundary, when its shared build/config inputs
already require the milestone's complete validation. Current feature rechecks
use separate frozen production source and physical private oracle assets.
Private evidence: `.local/dragon-despawn-terrain-bad-nif.log`,
`.local/dragon-despawn-vanilla-interrupted.log`; the initial library had the
same inode as the main source artifact, while the corrected private copy does
not. Do not treat the interrupted run as a gameplay compatibility failure.
