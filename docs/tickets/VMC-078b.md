# VMC-078b — Isolate native artifacts between build profiles

Status: In progress
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

Prepare this change alongside the frozen client batch; its shared build/config
inputs receive the milestone's complete validation after gameplay fixes settle.
Current feature rechecks use separate frozen production source and physical
private oracle assets.
Private evidence: `.local/dragon-despawn-terrain-bad-nif.log`,
`.local/dragon-despawn-vanilla-interrupted.log`; the initial library had the
same inode as the main source artifact, while the corrected private copy does
not. Do not treat the interrupted run as a gameplay compatibility failure.

## Implementation preparation

The project native compiler runs Cargo and uses Rustler's artifact parser,
then copies the returned library directly into its own physical Mix app
assets. Rustler retains its loader; it no longer compiles into source
`priv/native`. Native source resources still invalidate its Elixir module.
The loader names its environment's file, so a leftover old source library
cannot replace it during Mix's ordinary asset-copy step. Dev/test share
the identical fast profile, while prod and bench have separate Cargo
outputs for their different parity features. The obsolete `build_embedded`
claim and oracle environment flag are removed.

The first dev and private oracle builds pass. A real production NIF and
the parity random-source NIF both load from the dev artifact, and 22
affected dragon, natural-spawning and joined-chest owner checks pass.
Real prod/bench builds overlap successfully in separate output roots. During
them the private checker makes 150 successful seeded random/production NIF
calls and retains identical native bytes. Fresh no-compile reloads find no
parity export in prod and the parity export in bench. The isolated assembled
release also loads the production NIF and refuses the parity stub without
starting a server. All five app asset directories are physical with distinct
version-file inodes; the legacy source library remains unchanged during the
proof and is retired afterward. The compiler clears its old private assets
before copying, so removed data cannot linger in a later build.

Evidence: `.local/m3-build-isolation-*.log`,
`.local/m3-build-isolation-manifest.json`, the retained probe scripts and
source-before JSON. The final dragon motion repair passes the 561-check
fast suite and all 243 vanilla stages selected by these shared build inputs
(572 seconds, 269 cache hits, no unverified extraction). The combined
immutable production release also builds successfully under
`.local/M3-finale-motion-checkpoint`; its source matches runtime patch
SHA-256 `e35823da9c6af501f3cca0c20461a657a01b19d5becf1d67610ae5266d1af3a6`.
Logs: `.local/dragon-motion-build-fast.log`,
`.local/dragon-motion-build-vanilla.log` and
`.local/finale-motion-frozen-release.log`. The full M3 suite and the
remaining client gates still precede milestone completion.
