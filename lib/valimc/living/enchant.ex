defmodule Valimc.Living.Enchant do
  @moduledoc """
  The enchantment engine (VMC-037q, `valimc_core::mobs::living::enchant`)
  for players: vanilla's `EnchantmentHelper` hooks over the effect
  components of the pinned data pack, through `Valimc.Native.enchant_*`.
  Mobs call the same engine in Rust. The living facts must be installed
  (`Entity.MobFacts.install!/0`, at application start).

  Enchantments are `[{name, level}]` (`levels/1` of a stack). A context holds
  the loot context's entities (`entity/1`), the damage (`{type id,
  direct?}`), the tool's item id, the weather and the block at the origin
  (`{block id, can see sky}`). Entity hooks answer actions for the caller to
  apply, in order:

  - `{:mob_effect, name, ticks, amplifier}`, `{:ignite, seconds}`,
    `{:damage, amount, damage type}` (caused by the item's owner),
    `{:item_damage, points}` (the enchanted item), `{:exhaustion, amount}`,
    `{:impulse, direction, scale, magnitude}` (along the look);
  - `{:sound, name, volume, pitch}`, `{:particles, spec}`,
    `{:summon, types, join_team}`, `{:explode, spec}`,
    `{:replace_disk, spec}`;
  - `{:add_modifier, attribute, id, amount, operation}`,
    `{:remove_modifier, attribute, id}` (location effects).

  Random draws come from a legacy random seeded from `:rand`.
  """
  alias Valimc.Native
  alias Valimc.Protocol.ItemStack
  import Bitwise, only: [<<<: 2]

  @entity %{
    type_id: 0,
    on_ground: false,
    in_water: false,
    fall_flying: false,
    flying: false,
    vehicle: false,
    can_see_sky: false,
    affected_by: nil,
    horizontal_speed: 0.0,
    fall_distance: 0.0,
    tick_count: 0,
    player: nil
  }
  @context %{
    this: nil,
    attacker: nil,
    direct: nil,
    damage: nil,
    tool: nil,
    thundering: false,
    block: nil
  }

  @doc "A stack's applied enchantments as `[{name, level}]` (none for nil)."
  def levels(nil), do: []

  def levels(%ItemStack{components: components}),
    do: components |> Map.get("minecraft:enchantments", %{}) |> Enum.sort()

  @doc "An entity view for requirements: `fields` over the defaults."
  def entity(fields), do: Map.merge(@entity, Map.new(fields))

  @doc "A context: `fields` over the defaults."
  def context(fields \\ %{}), do: Map.merge(@context, Map.new(fields))

  @doc "A value hook (`:item_damage`, `:ammo_use`, `:block_experience`...) on `value`."
  def value(hook, enchantments, ctx, value) do
    {:ok, {out, _}} =
      Native.enchant_value(
        Atom.to_string(hook),
        enchantments,
        context(ctx),
        seed(),
        value * 1.0
      )

    out
  end

  @doc "An unconditioned value hook (`:crossbow_charge_time`, `:trident_spin_attack_strength`)."
  def unconditioned(hook, enchantments, value) do
    {:ok, out} = Native.enchant_unconditioned(Atom.to_string(hook), enchantments, value * 1.0)
    out
  end

  @doc "`forEachModifier(stack, slot)`: `[{attribute, id, amount, operation}]`."
  def modifiers(enchantments, slot) do
    {:ok, out} = Native.enchant_modifiers(enchantments, Atom.to_string(slot))
    out
  end

  @doc """
  `doPostAttack` of one item held by `enchanted` (`:attacker` or `:victim`)
  in `slot` (nil: all its enchantments): `[{affected, action}]`.
  """
  def post_attack(enchanted, enchantments, slot, ctx) do
    {:ok, {out, _}} =
      Native.enchant_post_attack(
        Atom.to_string(enchanted),
        enchantments,
        slot && Atom.to_string(slot),
        context(ctx),
        seed()
      )

    out
  end

  @doc """
  An entity hook (`:tick`, `:projectile_spawned`, `:hit_block`,
  `:post_piercing_attack`) of one item in `slot` (nil: all its
  enchantments).
  """
  def entity_hook(hook, enchantments, ctx, slot \\ nil) do
    {:ok, {out, _}} =
      Native.enchant_entity(
        Atom.to_string(hook),
        enchantments,
        slot && Atom.to_string(slot),
        context(ctx),
        seed()
      )

    out
  end

  @doc """
  `runLocationChangedEffects` for the item in `slot`: `{actions, active}`,
  where `active` is the entity's list of active location effects.
  """
  def location_changed(slot, enchantments, active, ctx) do
    {:ok, {actions, active, _}} =
      Native.enchant_location(Atom.to_string(slot), enchantments, active, context(ctx), seed())

    {actions, active}
  end

  @doc "`stopLocationBasedEffects` for the item leaving `slot`: `{actions, active}`."
  def stop_location(slot, enchantments, active) do
    {:ok, out} = Native.enchant_stop_location(Atom.to_string(slot), enchantments, active)
    out
  end

  @doc "How many of `enchantments` acting in `slot` have value component `hook`."
  def count_with(hook, enchantments, slot) do
    {:ok, count} =
      Native.enchant_count_with(Atom.to_string(hook), enchantments, Atom.to_string(slot))

    count
  end

  @doc "A crossbow's charging sounds (`{start, mid, end}`, each nil or a name), nil for the defaults."
  def charging_sounds(enchantments) do
    {:ok, sounds} = Native.enchant_charging_sounds(enchantments)
    sounds
  end

  @doc "The trident sound of the highest-levelled enchantment with one (`trident_sound`), or nil."
  def trident_sound(enchantments) do
    {:ok, sound} = Native.enchant_trident_sound(enchantments)
    sound
  end

  @doc "Curse of Binding's `prevent_armor_change`."
  def prevents_armor_change?(enchantments) do
    {:ok, {armor, _drop}} = Native.enchant_flags(enchantments)
    armor
  end

  @doc "`replace_disk`'s candidate positions around `position`, before its predicate."
  def disk_positions(position, offset, radius, height) do
    {:ok, out} = Native.enchant_disk_positions(position, offset, radius, height)
    out
  end

  defp seed, do: :rand.uniform(1 <<< 48) - 1
end
