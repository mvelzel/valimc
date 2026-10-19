# VMC-034n — Earned cooking output and XP awards

Status: In progress. [Award values](VMC-034n1.md) and
[pending storage](VMC-034n2.md) are complete within unused foundation scopes.
The [orb materialization kernel](VMC-034n3.md) is also validated at `d95273c`;
owner-fenced runtime publication/handoff remain next, followed by XP/player authority
and recipe delivery.
Output with recipe uses stays refused until the complete award path is admitted.

Player withdrawals must release the earned output, award used recipes and spawn
the corresponding experience exactly once. Removing a processor must preserve
both stored items and earned experience. Do not replace native orbs with a direct
inventory-click XP grant.

Reference: Mojang 26.3 server SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`;
`FurnaceResultSlot.checkTakeAchievements`,
`AbstractFurnaceBlockEntity.awardUsedRecipesAndPopExperience`,
`getRecipesToAwardAndPopExperience`, `createExperience`, `preRemoveSideEffects`.
Private bytecode: `.local/cooking-menu.javap`, `.local/cooking-slot-hooks.javap`.

Observed native rules: manual pickup/quick crafting invokes the award hook.
It processes the stored recipe-use counts, spawns experience at the player's
position, awards recipes and then clears the uses. Each recipe multiplies count
and XP using float32, floors the result and adds one when a native float draw is
below the fractional remainder. Credit is not proportional merely to the output
count removed by the current click. Processor removal also invokes XP release.

Acceptance:

- Native differential values/RNG boundaries, mixed recipes and partial/quick
  withdrawals; preserve credit through operations that do not invoke player awards.
- Bound region-owned XP records and pure worker work; use player ownership for
  durable XP state. Define ordering, award identity, receipts and recovery before
  enabling output. No speculative awards or lost credit on capacity refusal.
- Commit item withdrawal, cleared recipe credit and the durable award effect as
  one recoverable decision. Recovery, replay, owner replacement and uncertain
  player delivery must neither mint another award nor lose the first.
- Interoperate with native XP spawning/pickup/player synchronization and recipe
  synchronization; track broader mending/advancement dependencies explicitly.
- Actual client: all processor families, partial/quick take, visible orb pickup,
  XP display, shared-menu competition, destruction and reconnect/restart
  conservation. Native probes cannot replace these actions.

Keep the current refusal until orb/player/recipe ownership, persistence and joint
delivery are tested. Values, pending storage and the orb kernel need no reimplementation.
