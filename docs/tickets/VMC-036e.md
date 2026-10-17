# VMC-036e — Stock food status callbacks

Status: Done within stock-food scope at9246b50, integrated through8cceaae.
86 affected/1,386 full tests, production/full native integration/both TCP
transports and all five actual-client groups pass.

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

Owned completion admits exact stock callback groups only when every prospective
status is implemented. A failed chance cannot bypass unsupported effects; pufferfish
remains refused whole. Preflight/cancellation never draw. Completion draws one
unbiased24-bit float from the owning connection's OTP RNG per group, then feeds
selected ordered effects into the existing pure consumption transition. Meal,
count, effect map and golden hearts share its checkpoint; no extra timer/process.

86 affected checks pass(seed270019): actual TCP both-hand golden apples at full
food, cancellation without draws, grouped enchanted buffs in survival/creative,
success/failure for chicken/rotten flesh/poisonous potato, guaranteed spider eye,
exact single-draw advancement, atomic pending saves, fresh reconnect and pufferfish
whole refusal before nutrition/RNG. Tests seed only the owning process's RNG;
runtime has no testing strategy/override. Native callback foundation is unchanged.
Raw `.local/stock-food-live-targeted.log`. Graphical acceptance remains pending.

Actual26.3 client PASS on immutable9246b50; primary reviewed the dedicated report
once. Main/offhand golden apples cancel cleanly and eat at full food, granting
RegenerationII/AbsorptionI and two gold hearts. Enchanted apples visibly grant all
four buffs/eight gold hearts; creative retains the exact stock stack. Actual flesh,
chicken and poisonous potato meals show both seeded chance branches with nutrition;
spider eye shows Poison/damage. Pufferfish is refused whole at this older admission
checkpoint. Fresh direct reconnect retains accepted apple2/food14/saturation9.6/
pool4 without replay, with duration decreasing2158→1899. No post-acceptance fixtures.
Chance samples use documented owner RNG seeds, not statistical distribution proof.

Both wrappers/JVMs and server63778 stopped; five regions+clock flush:ok, zero
connections/players and all1,000 frozen blobs unchanged. Whole final dataset
`/tmp/valimc-stock-food-live-client-20261016`: survival,16HP from actual Poison,
apple2/food14/saturation9.600000381469727, pool4/Absorption1600ticks, source61/
outboxnil and region{2,2}receipt61. No health or journal resets. Private report,
fixtures/traces, cleanup and hashes: `.local/client-tests/VMC-036e/report.md`,
`.local/stock-food-live-cleanup.log`, `.local/stock-food-publication-proof.json`.
Final larger native integration at8cceaae exited0, including both TCP transports
(completion collected October18). All gates pass; pufferfish admission is completed
by VMC-037k at8cceaae.
