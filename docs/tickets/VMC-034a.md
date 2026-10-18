# VMC-034a — Furnace fuel foundation

Status: Pure fuel resolver implemented; production and dedicated client baseline
pending. No live furnace/cooking claim.

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


October18 pinned26.3/server33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c:
original CookingFuelOracle invokes actual getBurnDuration/getSpeedMultiplier for
all1,658 stock items, explicit cooking_fuel removals and all24 orientation/lit
states of furnace/smoker/blast furnace. All79,584 callbacks match. The347 fuels
collapse to14 scalar profiles; no component definitions or upstream source are
published. Fast cooking halves duration with integer truncation and uses speed2;
dried kelp block is4001/2000 ticks, carpet67/33. Private raw declarations/callbacks
`.local/cooking-fuel-native.json`; comparison `.local/cooking-fuel-comparison.log`.

CookingFuel.resolve/2 uses immutable compiled lookups, validates item patches,
honors explicit removal, preserves unrelated names and refuses unsupported
cooking_fuel overrides/context. No process, timer, inventory mutation or gameplay
caller is added. Nine affected checks pass(seed319927), including removal/name/
invalid-stack/context boundaries (`.local/cooking-fuel-targeted-final.log`).
Targeted native probe, changed formatting, Python compilation and public audit
pass. Baseline client scenario for this unused kernel: fresh direct join, normal
HUD/empty-chest open/close and fresh reconnect with exact saved quantities/receipts.
This baseline cannot establish fuel consumption or smelting.
