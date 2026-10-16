# VMC-036e — Stock food status callbacks

Status: Researching native stock callbacks and probability boundaries.

Acceptance: stock foods with supported status effects (including golden apples,
rotten flesh, raw chicken and poisonous potato) apply their complete native callback
groups/chances exactly once at consumption completion. Food, effects, golden-heart
pool and remaining item share one owner checkpoint. Cancellation and reconnect
never reroll an accepted meal; unsupported prospective effects refuse the whole
food before use. No global RNG/gameplay process; use the owning connection's RNG.

First extract pinned default callback facts and prove actual native probability
comparisons, one draw per callback/group, ordered additions and independent effect
copies. Keep Java RNG implementation parity outside the gameplay contract; native
draw precision, threshold distribution and retry consistency remain explicit.

Client: actual golden/enchanted apples show their complete supported buffs and
golden hearts, including full-food eligibility and creative retention; rotten
flesh/chicken show native nutrition with observed chance outcomes over a bounded
sample. Actual poison food, cancellation, unsupported negatives and fresh reconnect
retain one accepted meal without reroll or extra consumption. Delegate to the
dedicated tester after a frozen production release. Native proofs do not replace GUI.

Reference: pinned26.3 Consumable.onConsume, ApplyStatusEffectsConsumeEffect,
FoodProperties, stock item initializers and existing PlayerConsumption/Absorption.
Potion delivery and timed status implementations are dependencies, not proof of
food callback behavior. Suspicious stew, custom consumable components, teleporting
foods and unsupported effects remain separate slices. Keep jars/bytecode/raw data
ignored; publish original probes and small facts only.
