# VMC-036e — Stock food status callbacks

Status: Native facts/chance foundation verified; live food callbacks unsupported.

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

October16: `ConsumeStatusOracle` extracts seven stock apply-status records and
executes112 actual callback boundary cases. One draw always occurs per callback,
including probability0/1 and empty groups; draw<probability selects every effect
in native list order. Fresh effect instances are copied for each attempt, even
when additions report unchanged. Golden apple grants RegenerationII100/AbsorptionI
2400; enchanted grants RegenerationII400, ResistanceI/FireResistanceI6000 and
AbsorptionIV2400. Chicken/rotten flesh chances are native float0.3/0.8; poisonous
potato0.6 and spider eye1. Pufferfish has Poison/Hunger/Nausea together and must
remain unsupported until all are implemented. Scalar facts live in
`priv/protocol/consume_status.json`; private callback bytecode/raw native observations
stay ignored. Original code controls only the float draw/add-result endpoints;
actual native grouping/copy/iteration/comparison runs. Gameplay and admission are
separate. `StockFoodEffects` provides default-policy selection and pure group
resolution with caller-supplied native floats; it is not wired into live use yet.
Eleven affected checks pass(seed646160), including chance equality, grouped order,
draw count/precision, native defaults and unexpected-listener refusal.
Raw `.local/consume-status-{native,elixir,targeted}.log`.
