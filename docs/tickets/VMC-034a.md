# VMC-034a — Furnace fuel foundation

Status: Researching; no live furnace claim. Chest physical/sound gates continue
independently in VMC-032a10/a11.

Acceptance for this slice: stock26.3 cooking-fuel defaults and contextual resolution
match native observations; explicit component removals and unsupported patches do
not silently become fuel. Record the exact source/context and bounded pure lookup
tests before admitting gameplay.

Pinned AbstractFurnaceBlockEntity.getBurnDuration/getSpeedMultiplier use the
CookingFuel component and resolvable int/float providers. A historical item-ID
burn-time table is insufficient. First inspect stock components/provider references,
then exercise actual native resolution in a supplied block context. Private
signatures/bytecode `.local/{furnace-native-*,cooking-fuel-signatures}.javap`.

Later work needs three owned slots, bounded active-region cooking work, recipe/
fuel/remainder/XP semantics, atomic item changes, persistent progress and a native
furnace menu. Sleeping furnaces must require no per-block process or polling.
Dedicated actual-client acceptance must eventually smelt/consume fuel, collect
output, refuse invalid inputs and preserve quantities/progress across reconnect.
