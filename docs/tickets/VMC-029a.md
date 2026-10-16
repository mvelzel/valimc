# VMC-029a — Survival mining

Status: Basic live survival mining actual-client/TCP verified; full native block
integration and broader block/loot/callback coverage pending. October 16, 2026.

Acceptance: survival players can mine with native tool speed, break progress,
harvest permission, drops and durability. Handle start/abort/stop acknowledgements,
range, changed tools/blocks, modes, loading, disconnect and concurrent miners.
Only the block owner commits destruction and drops; item/tool consequences need
explicit conservation and recovery. Bound pending work per player and coalesce
crack replication. No process per block or global mining timer.

Start with native block hardness/progress and its float32/tick boundaries, then
tool facts, fenced owner mining, atomic destruction/drops and durability. Kernel
probes with supplied player speed/harvest permission do not establish tool/effect
or complete live mining parity. Creative destruction remains a separate path.

Stock tools: original `MiningToolOracle` binds native block tags and inspects all
1,658 item method declarations. The 32 default profiles match 1,143,136 actual
state speed/harvest pairs, all item destruction permissions and 3,316 removed-tool
controls. Ordered speed and harvest rules are independent: iron retains speed6
on obsidian but cannot harvest it. Native swords have maximum-float bamboo speed
and forbid creative destruction; removed tools lose both rules. The debug stick
always forbids destruction; its privileged block interaction remains separate.
Four affected boundary tests pass. Facts include base durability cost, without
claiming actual wear/loot behavior. Logs `.local/mining-tool-{native,check,tests}.log`;
raw cases and native dumps stay ignored. `Item/ItemStack` tool methods and
`Tool.getMiningSpeed/isCorrectForDrops` use the same pinned jar below.

Player speed: actual `Player.getDestroySpeed/hasCorrectToolForDrops` matches8,112
equipment attribute cases, 64,896 geared speed contexts and338 stock speed/harvest/
composed-rate contexts. All Efficiency/Aqua Affinity levels0..255, direct/stored
enchantments and six slots are checked. Efficiency only boosts a fast selected
main-hand tool and caps at1,024; head-only Aqua Affinity scales native submerged
speed up to20. Eye-water and airborne penalties preserve float32 ordering,
including overflow to infinite speed. All13,264 stock item/slot modifier controls
are zero. The probe explicitly applies native equipment modifiers and disables
status effects; it does not exercise automatic equipment refresh or a live world.
Six affected tests and existing mining/tool native regressions pass. Logs
`.local/player-mining-{native,check,tests,arithmetic-regression}.log` and
`.local/mining-tool-refactor-{native,check}.log`.

Stock [mining durability](VMC-029a2.md) now matches39,704 actual native callbacks,
including shears/zero hardness, removed components, direct/stored Unbreaking,
break payloads and custom integer boundaries. Six affected checks pass; live
composition remains pending.

[Atomic persistence](VMC-029a1.md) now includes source intent, receipt-backed wear
compensation and login/disconnect recovery, with101 affected tests passing.
The first [loot catalog](VMC-029a4.md) matches210,847 native contexts for930
deterministic block families, including direct/stored Silk Touch controls. Random
and contextual rules remain explicit unsupported results. The pure
[attempt/animation foundation](VMC-029a5.md) matches490 native action traces and165
codecs, with an explicit elapsed-tick correction for delayed completion.
Renewable block fencing and [basic live composition](VMC-029a6.md) are implemented.
The six basic block kinds, cracks/abort, current tool, loot/wear and reconnect
passed actual-client checks on `c163209`. Full native block integration is running;
[stateful counts/slabs](VMC-029a7.md) extend coverage independently.
[Base removal](VMC-029a3.md) now retains contained fluid, matching all35,723 native
states and71,446 actual removal callbacks; wet mining recovery/creative TCP pass.
Actual wet/dry creative removal, fresh-client persistence and basic responsiveness
passed on immutablea696a61; base removal is complete within that scope.
Status effects/arbitrary attribute patches and the live client scenario remain
pending; current stock gear/contact composition needs no global gameplay owner.

Reference: pinned Mojang 26.3 `BlockBehaviour.getDestroyProgress`,
`BlockStateBase.getDestroySpeed`, `Player.getDestroySpeed/hasCorrectToolForDrops`
and `ServerPlayerGameMode.handleBlockBreakAction/tick/destroyBlock`. Jar SHA1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Reference dumps stay ignored.

Foundation: original `MiningOracle` extracts all35,723 hardness/harvest flags in
46 compact property groups. Native comparisons pass1,286,028 rates, including
wrong-tool divisors, zero hardness, signed zero, subnormals and float overflow;
1,386 actual `ServerPlayerGameMode.incrementDestroyProgress` prefixes verify
elapsed+1 multiplication, crack casts and duplicate-notification suppression.
Two boundary regressions pass. Nonfinite Java results use explicit bounded
markers in Elixir. Immutable binary lookup replaces per-block objects. Logs
`.local/mining-{native,check,tests}.log`; raw cases stay ignored. The probe supplies
player speed/harvest permission and controls crack delivery; no loot/world/player
effects or live mining are established. Full-block/client checks remain pending.

Inspiration: pinned SteelMC `f6fb4e49778ccffc5c13c3b87c1c2600dd9435aa`,
`steel-core/src/player/game_mode/block_breaking.rs`, separates start/abort/delayed
completion and sends cracks only when their stage changes. Retain bounded local
attempt state on the player owner, with fenced block-owner commits. Native 26.3
controls exact arithmetic: Steel's zero-hardness shortcut returns1, whereas the
native method returns infinity or NaN depending on supplied speed. Do not copy
that shortcut into the kernel or treat the rewrite as a completeness oracle.

Client scenario: punch dirt/stone, compare correct/wrong tools, interrupt and
resume, switch tools, move out of reach and let a second miner finish. Inspect
world changes, stack/drop conservation, tool damage, reconnect and failed writes.
Delegate graphical checks on a frozen release; retain partial scope honestly.
