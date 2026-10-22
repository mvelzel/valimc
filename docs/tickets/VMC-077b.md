# VMC-077b — Native scheduling policy and NIF hygiene

Status: Done
Milestone: foundations II (between M2 and M3)
Depends on: [VMC-077](VMC-077.md) (the audit and plan).

Before: `native/valimc_nif/src/lib.rs` was one 2,392-line file of 72 NIF entries
in seven domains. `WorldgenWorkers` and `DecorationWorkers` were each sized to
the dirty CPU schedulers, so generation alone subscribed them twice and an
owner's dirty call (loot, light, NBT) queued behind 100 ms–seconds generation
jobs. Loot ran on dirty schedulers for microseconds of work. Each call site
chose normal or dirty by its own byte threshold. Sixteen oracle and benchmark
NIFs shipped in releases; `worldgen_proto_terrain` and `worldgen_proto_decorate`
had three arities between them; errors mixed about 43 atom and 42 string
conventions plus `{:ok, :ok}`; the Region resource accepted changes from any
process; positions crossed as lists of tuples and every output binary was
copied once more from a `Vec`; the worldgen state pool kept a hard-coded 64.

Scope: the NIF crate, `Valimc.Native`, the generation pool children and the
call sites that pick schedulers or match NIF results. Not here: light dispatch,
halo work and light NIF semantics (VMC-077c, which uses `dispatch/3`), the
generation scheduler and `SeedContext` (VMC-077n), the command side of
`/locate` and `/place` (VMC-077a, which runs them through the pool), block
facts and the Rust fact install (VMC-077d).

Acceptance:

- One module per domain: `region`, `light`, `codec` (disk NBT, LZ4, column
  images), `sys`, `worldgen`, `loot`, `parity`; Rustler collects the NIFs from
  all of them (3728248, the 72 entries unchanged). `stage_changes.py` maps a
  change in any module to the NIFs it reaches.
- `Valimc.Worldgen.Pool` is the one generation pool: dirty CPU schedulers minus
  two, at least one. Terrain starts as bulk work, which leaves the last slot to
  decoration, full chunks and commands; `run/2` (added by VMC-077a) runs
  `/locate` and `/place` in it. `WorldgenWorkers` and `DecorationWorkers` are
  gone. The worldgen state pool keeps `Pool.size()` states.
- `Valimc.Native.dispatch/3` is the one place that picks a normal NIF or its
  dirty twin, by measured worst-case cost against a 1 ms budget: disk NBT 8 ns
  per input byte (terms included), LZ4 0.5 ns per output byte priced at the
  most an input can expand to (255 times), `set_blocks` 40 ns per change,
  `random_ticks` 5 ns per draw. The last two gained dirty twins: `/fill`, a
  region load replaying its edits, or a high `randomTickSpeed` exceeded 1 ms
  on a normal scheduler (51,200 changes took 1.9 ms; 4,096 draws per section
  27 ms). `loot_fill` and `loot_items` run on normal schedulers.
- Results: `{:ok, value}`, or `:ok` without one; an expected failure is
  `{:error, atom}` from its domain's closed set (`:not_owner`,
  `:invalid_positions`, `:light_facts_missing`, `:unknown_loot_table`, `:file`'s
  posix atoms for the syncs and the open-files limit, the NBT and LZ4 atoms);
  a broken invariant raises (worldgen and loot facts the generator cannot run).
  `/place`'s span limit is a `:too_large` plan, not an error string. Nothing
  returns `{:ok, :ok}`.
- Oracle and benchmark NIFs build only with the `parity` cargo feature, on for
  dev, test and bench (`config/config.exs`), off for releases. Gone: the legacy
  `worldgen_proto_terrain/3` and `worldgen_proto_decorate/3,4`, `diff` and
  `compact` (only tests reached them), `Blocks.image/1,2`, `Blocks.put_column`,
  `Blocks.heap_bytes`, `Blocks.compact` and `Light.columns`; the core's
  `ColumnStore::diff` and `compact`.
- The Region resource records the process that created it; `with_owned` refuses
  every change from another (`{:error, :not_owner}`), reads stay open
  (`blocks_test.exs`).
- `get_blocks`, `set_blocks`, `chunk_find` and `random_ticks` take and return
  packed big-endian binaries. Outputs over 64 bytes become resource binaries
  that point into the Rust buffer (no copy); dense snapshots, dumps, packed
  palettes and position records are written straight into their binaries.

Measurements (`bench/dirty_capacity.exs`, raw results in
`bench/results/vmc-077b-dirty-*.json`): a fresh decorated world finalizes 3 × 3
regions at once while a probe stands in for play, calling every 10 ms a dirty
NIF (the disk NBT reader on 64 KB, 0.3–0.6 ms idle) and a normal one. Two
alternating before/after pairs on the 10-core host with 10 dirty CPU
schedulers, load averages 28–36 from other sessions:

| | Before (b06e324: two pools of 10) | After (53a912a: one pool of 8) |
|---|---|---|
| Dirty probe p50 / p90 / p99, ms | 0.8–4.9 / 34–93 / 70–164 | 0.9–1.2 / 4.9–12.4 / 11.5–63 |
| Dirty probe max, ms | 157–193 | 48–94 |
| Normal probe p99, µs | 23–146 | 10–19 |
| Dirty CPU utilization | 0.72–0.82 | 0.52–0.64 |
| Normal utilization | 0.008–0.011 | 0.007–0.012 |
| Final chunks per second | 173, 140, 83, 93 | 120, 76, 165, 137 |

Owners' dirty calls now wait for a free dirty scheduler instead of a full queue
of generation jobs; generation throughput is within this host's noise (medians
116 before, 128 after).

Checks: `cargo test --release --features valimc_nif/parity` (76 passed);
`cargo clippy --all-targets` with and without the feature and `cargo fmt
--check` clean. The generation files with slow suites (19 passed after the
pool), the 30 native-touching files with slow and socket suites (104 passed),
`mix test.fast` (502 passed). Vanilla stages: `config/*` and the crate's
`Cargo.toml` are global inputs, so every stage ran at 203b802: 203 of 214
passed; the other 11 failed on scripts VMC-077a had not yet moved to
`World.Spec` and passed after its 90bf037 (`--only` those 11, 11 passed).

Next: VMC-077c moves light onto `dispatch/3` (light update by positions, halo
edits) and packs light positions. Deferred: loot returns structured stacks
instead of NBT terms; registries parse fact files in Rust instead of a decoded
term tree; `full_sync` and `fsync_dir` open files outside `FileBudget`;
`entity_kind`'s global mutex and leaked strings; fluid tick names as strings in
`worldgen_proto_full`; copy-on-write section snapshots as resources (audit G3).

Client: interim VMC-077 run on the frozen release of b8646a33 (October 22, 2026; evidence in ignored `.local/client-tests/VMC-077-interim/`): generation, teleports and travel played on these pools with no stalls. PASS.
