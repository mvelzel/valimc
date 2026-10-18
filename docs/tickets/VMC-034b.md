# VMC-034b — Atomic furnace item transitions

Status: Pure slot proposals implemented; production/client baseline pending.
VMC-034a owns contextual fuel resolution. No live cooking.

Acceptance: a bounded pure three-slot proposal consumes one fuel/input, preserves
component identity, admits complete recipe output only when it fits, and returns
any fuel remainder overflow for mandatory durable world admission. No partial
slot change may escape a rejected proposal. Cover wet sponge/bucket behavior.
Use actual pinned AbstractFurnaceBlockEntity.canBurn/burn/consumeFuel observations;
raw dumps stay ignored. Contextual fuel admission, recipes, timers, journal/menu
ownership and XP remain separate until their complete protocols are implemented.

Client scenario for an unused kernel: fresh direct join, stable HUD and an ordinary
chest open/close/reconnect with exact saved quantities. This baseline establishes
interoperability only; actual smelting must pass after runtime integration.

The future region owner reserves the complete three-slot mutation, runs bounded
pure work and commits item changes/progress through the same durable authority.
An active-work index schedules batches; sleeping blocks have no process or poll.


October18 pinned26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c:
CookingItemsOracle invokes actual private canBurn/burn in37,440 cases over result/
output identities, names, explicit/removed stack limits, count/capacity boundaries,
ordinary/wet-sponge inputs and empty/named/multiple buckets. All match the original
Elixir proposal. Native consumeFuel matches1,960 cases over all347 stock fuels,
valid counts/names and patched99-capacity lava buckets. Five numeric stock
crafting-remainder pairs are retained; only lava bucket is a stock fuel among them.
Raw `.local/cooking-items-native.json`, comparison `.local/cooking-items-comparison.log`.

Consumption retains the source patch when fuel remains, uses a fresh stock
remainder when the slot becomes empty and returns overflow separately. Completion
retains existing output patches when effective identity matches. Wet sponge uses
the native whole fuel-slot bucket replacement, including its name/count reset.
Output refusal returns no changed slots. No live recipe, tick, XP or journal caller
exists. Twelve affected checks pass(seed788254), including blocked atomic output,
identity equivalence/difference, sponge and remainder/invalid-fuel boundaries
(`.local/cooking-items-targeted.log`). Production and unused-kernel baseline pending.
