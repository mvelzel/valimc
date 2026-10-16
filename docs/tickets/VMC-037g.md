# VMC-037g — Instant Health and Instant Damage

Status: Native drink-request foundation verified locally; no live support claimed.

Acceptance: actual healing/harming drinks apply once at completion, with native
amounts/source and supported defenses, no persistent instant-effect icon. Keep
health, container/count, mixed effects and fatal consumption/death recovery on the
existing owner/checkpoint lane. Cancellation, creative/modes and reconnect must
preserve accepted state; no separate timer or effect owner.

Client: actual healing/harming and stronger drinks, cancellation, both hands,
defenses, mixed timed effects, fatal drink/respawn and fresh reconnect without
reapplying or duplicating the container.

Pinned26.3: `PotionContents.applyToLivingEntity/onConsume`,
`HealOrHarmMobEffect.applyInstantaneousEffect/applyEffectTick`,
`InstantaneousMobEffect`, existing health/defense and durable consumption code.
Private bytecode: `.local/instant-{PotionContents,HealOrHarmMobEffect,InstantaneousMobEffect}.javap`.
Player drinking attributes its harmful magic to the drinking player. Do not
silently reuse the no-attacker periodic poison source. JVM signed shift/wrap and
negative high-amplifier healing requests need explicit proof before live handling.

First slice intercepts native drink health requests only, including all256
amplifiers and custom duration/scale inputs. It cannot prove downstream health,
armor, death text, inventory durability or actual-client behavior.

October16: original `InstantDrinkOracle` invokes actual
`PotionContents.applyToLivingEntity` on a controlled player/server-level context;
only heal/hurt endpoints are intercepted.10,240 cases cover both effects, all256
amplifiers, infinite/zero/finite/maximum durations and four duration scales. Amounts
match exactly and harmful sources retain both direct/causing self attribution.
`InstantEffect.drink_request/2` reproduces signed32 shifts and the native
double-to-int-to-float request. Duration scaling does not change instant strength.
Three boundary checks pass. The first comparison exposed Gson's short Float
decimal representation at high magnitudes; the probe now writes promoted doubles
so comparisons retain the actual native float bits. Evidence:
`.local/instant-drinks-{native-final,native-check-final,targeted-final}.log`.
Negative/zero requests remain requests only; full native downstream consequences
and durable consumption/death composition still need implementation.

Self-attribution protocol foundation: `SelfMagicOracle` uses actual native
DamageSource death messages and the entity/source damage-event constructor.32
fixtures cover four entity-ID boundaries, two names and empty/stock/custom-named/
item-name-only mainhands. Elixir self-magic events retain both source entity IDs;
24 plain-mainhand messages include the player twice. All80 independently encoded
event/death/chat packets native-decode to the expected messages. Six affected
packet/request checks pass. Evidence: `.local/self-magic-{native-final,check,decode,targeted}.log`.

Named mainhands select `death.attack.indirectMagic.item` and include the actual
styled item/hover component; item-name alone does not. This named-item message is
observed but not yet implemented. Capture the original mainhand before replacing
the consumed container, including when drinking offhand. The new event/template
helpers are unwired; instant drinking still remains unsupported.

Signed healing foundation: `PlayerHealth.heal/2` matches195 actual native
`LivingEntity.heal/setHealth` transitions, using the real synchronized health
accessor with a controlled maximum and unrelated notifications suppressed. Zero,
subnormal, ordinary, maximum, negative and signed instant requests clamp correctly;
dead players do not revive. The initial probe tried an incomplete whole-entity
builder; it now constructs only the real health accessor required by this method.
44 affected health/request/consumption checks pass(seed946132), including corrected
Night Vision fixture lookup (the prior numeric15 was another unsupported effect).
Evidence: `.local/healing-{native-final,native-check-final,targeted-final}.log`.
This helper is not yet wired into instant consumption or death adjudication.

Larger block integration is frozen at `cc3dfa5` (961 unchanged source blobs):1,330
full tests and production pass with four BEAM schedulers; full native integration
is running independently (`.local/effects-integration-{full-tests,production,full-native}.log`).
That checkpoint contains movement effects and instant request math, before the
later self-magic and signed-healing helpers; their targeted proofs remain separate.
