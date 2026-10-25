# VMC-080j — Tick only eligible entities and cooking processors

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).
Depends on: [080h](VMC-080h.md).

One active chunk currently ages every entity and can cook every processor in its
8×8 storage section. Use the existing spatial membership index to select entity
counter work by active chunk, preserving inactive neighbours as interaction
targets. Keep missed ageing budgets per chunk, so newly activated chunks do not
inherit another chunk's debt. Knot checks count executed turns, not global time.

Cooking selection must follow current chunk tickets, wake on eligibility changes
and reject results for processors that became inactive before adoption. Preserve
container/item/block atomicity and existing worker fences. This does not change
simulation radius, owner topology, AI turn ordering or the language boundary.

Acceptance:

- Inactive mob cooldowns, item/orb ages and below-world removals stay untouched;
  reactivation advances one eligible turn without elapsed inactive-time catch-up.
- Same-tick ageing/movement fences survive sibling moves. Active XP scans can
  still absorb passive neighbours; no scan starts from an inactive orb.
- Planning debt stays bounded to a section's chunks and follows eligibility.
- Knots check support after 101 executed turns, including across inactive gaps.
- Cooking in a partially active section advances only eligible processors;
  activation wakes sleeping processors and outstanding results are checked again.
- Targeted owner/entity/cooking checks, affected vanilla stages and a matched
  ageing workload pass. Deploy committed changes to the same Hetzner world and
  32/10 settings for the user's own gameplay/profile, with no graphical tester.

Reference: pinned vanilla 26.3 `ServerLevel.tick`, `BlockAttachedEntity.tick` and
the 080h source provenance. Eligibility governs who executes a turn; it does not
remove inactive entities from observations or make them immune to active effects.

Implemented in Elixir over the existing owner-local membership index. Sparse
workloads use chunk buckets; when at least half the entries are eligible, a direct
scan avoids reconstructing a dense population from small sets. Only selected
entries get ageing markers and counters. XP scan candidates come from adjacent
chunk buckets and include passive orbs. Per-chunk deferred budgets remain bounded
to the section's 64 chunks. Knot support checks retain unsaved executed-turn
counters through same-owner adoption. Cooking stamps include ticket membership,
block reads cover selected processors, and results recheck current eligibility;
newly activated processors still wake after an older valid result lands.

Matched local `MIX_ENV=bench` comparison: 2,048 identical cows over 64 chunks,
the same one-turn budgets and complete equal result terms, seven alternating
pairs of 20 calls after warmup. Compare adaptive selection with a linear
eligibility scan using the same ageing implementation:

| Eligible cows | Linear median | Adaptive median | Linear / adaptive reductions |
|---|---:|---:|---:|
| 32 | 179.4 µs | 48.5 µs | 41,327 / 2,604 |
| 512 | 648.0 µs | 444.0 µs | 82,139 / 45,582 |
| 2,048 | 3,025.1 µs | 2,818.2 µs | 212,062 / 211,874 |

The full-population case uses the direct fallback; no material improvement is
claimed there. This shared macOS ARM64 host has ten schedulers, Elixir 1.20.4 and
OTP 29.1.1; concurrent verification adds timing noise. The fixture measures
eligibility plus ageing, without AI, movement, publication or durability. It is
not a whole-server comparison or a production TPS prediction. Raw pairs, script,
linear reference and source hashes remain in `.local/simulation-step/`.

Checks: 23 entity/index/counter/cooking tests, 52 owner/handoff/animal/cooking/
profiler tests and 25 dragon/shulker/navigation/native-sensing tests pass.
The selected vanilla run passes 20/20 stages, including the plain/encrypted TCP
session. The unchanged world-settings fact extraction has no cached regeneration
and remains unverified. Formatting and publication/docs/layer checks pass.
No new native code was needed for eligibility; the already verified native fluid
read and rare-type guards (080f/g), plus owner timings (080i), accompany this
deployment. User captures therefore compare the combined deployment, not just
one isolated change. No GUI client, hosting stress test or flight benchmark ran.

Deployed `f1d9fa85eb0292227b344bebce5d2ed17637138f` to the existing Hetzner
host on October 25. The production build, image identity, current symlink,
console RPC, persistent volume and 32/10 settings are verified. Minecraft TCP,
readiness, dashboard, live JSON, export and WebSocket upgrade checks pass.
No new player workload was driven; the user supplies the next gameplay profiles.
MSPT now includes lifecycle/commit preparation (080i), so its scope differs from
earlier captures. TPS, workload counts and the new owner/phase data guide the
next shared-frame refactor. Deployment evidence is retained with the parent.
