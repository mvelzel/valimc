# VMC-034d — Furnace progress transitions

Status: Pure progress kernel implemented; production/client baseline pending.
Depends on fuel, item and recipe foundations; no live cooking.

Acceptance: one bounded pure step matches pinned serverTick for fuel exhaustion/
refill, progress rescaling, blocked/missing input, completion and cooldown. Return
complete slot/progress/recipe-use/lit proposals and all remainder drops; callers
must durably admit the entire proposal. No timer callback may directly mutate
published inventory. Test actual native ticks and multi-tick traces, with no
per-block process. A region active-work index will schedule bounded batches.

Client baseline for an unused kernel: direct join/HUD, empty-chest open/close and
fresh reconnect without item changes. Actual smelting/menu/progress/restart
validation follows runtime ownership/journal integration.


October18 pinned26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c:
CookingTickOracle invokes actual serverTick with controlled world I/O, native
recipes/fuel/components and actual slot mutations.2,880 supplied boundary states
and15 traces of850 consecutive ticks (12,750 steps) match, including exact slots,
remaining/total burn, progress/total time, speed, block LIT and recipe-use records.
Continuity is checked between trace steps except explicitly recorded native slot
edits. Cases include fast refuelling, missing/blocked input/output, exhaustion,
removal/restoration, wet sponge and patched-fuel remainder overflow. Raw
`.local/cooking-tick-native.json`, `.local/cooking-tick-comparison-final.log`.

Cooking.step/2 returns a complete immutable state plus lit/completion/drop events.
It composes the prior kernels without publishing or doing I/O. Float32 division/
multiply and ceil preserve progress when new fuel changes speed. No-fuel cooldown
and lit missing-recipe retention are distinct native branches. Eleven affected
checks pass(seed589943), including200-step completion, blocked atomicity, fast
rescaling, same-step sponge/remainder composition and invalid state/context
(`.local/cooking-tick-targeted.log`). Runtime admission, persistence, active-region
scheduling, menu progress and XP remain unimplemented. Production/baseline pending.
