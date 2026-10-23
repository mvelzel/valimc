defmodule Valimc.Entity.Mob do
  @moduledoc """
  The living part of a mob's record (VMC-043a), as vanilla's `LivingEntity`
  and `Mob` hold it: its living state (`Valimc.Living`: health with its hurt
  and death timers, absorption, effects, fire, air, freezing), its equipment
  by slot, its attribute overrides over the type's defaults, its AI (`ai`:
  a `Valimc.AI.Mind` once it thought, or what its record kept of one: its
  random, VMC-041a), and whether it is persistent (a name tag's
  `setPersistenceRequired`, VMC-042a).

  Attributes are the type's generated defaults (`Valimc.Data.EntityTypes`)
  with `attributes` overriding a base value and adding modifiers, as
  `%{name => %{base: float | nil, modifiers: [{id, amount, operation}]}}`;
  its equipment adds its items' stock modifiers (`value/3`).

  A mob remembers the player who last hurt it for 100 ticks
  (`lastHurtByPlayer`): only a death within them drops experience and the
  player-only loot. `hurt_by` is the last living entity that hurt it, for
  VMC-041a's targeting.
  """
  alias Valimc.Data.{EntityTypes, Float32}
  alias Valimc.Living
  alias Valimc.Living.{Attributes, DamageSource, Health, Weapons}
  alias Valimc.Protocol.ItemStack

  alias Valimc.Entity.MobMotion

  @player_memory 100

  defstruct living: %Living{},
            equipment: %{},
            attributes: %{},
            ai: nil,
            # `NoAI`: no goals run (`Mob.isNoAi`); it still falls and is pushed.
            no_ai: false,
            motion: %MobMotion{},
            hurt_by_player: nil,
            player_memory: 0,
            hurt_by: nil,
            # What a death the owner has not dropped yet leaves (`Entity.Combat`).
            death: nil,
            # `PersistenceRequired`: a named mob never despawns (VMC-042a).
            persistent: false,
            # `LeftHanded`, `CanPickUpLoot` and the equipment's drop chances
            # by slot where not the default (VMC-043b).
            left_handed: false,
            can_pick_up_loot: false,
            drop_chances: %{},
            # The spawn reason of a mob whose `finalizeSpawn` is still to run
            # (its first tick runs it, VMC-043b), else nil.
            finalize: nil

  # `EquipmentSlot` ids, as the equipment packet numbers them.
  @slots [mainhand: 0, offhand: 1, feet: 2, legs: 3, chest: 4, head: 5, body: 6, saddle: 7]
  def slots, do: @slots

  @doc "A fresh mob of `type`: full health at its maximum."
  def new(type) do
    {:ok, health} = Health.restore(nil, max_health(type, %{}))
    %__MODULE__{living: %Living{health: health}}
  end

  @doc "The record a store saves."
  def record(%__MODULE__{} = mob) do
    %{
      living: Living.saved(mob.living),
      equipment: mob.equipment,
      attributes: mob.attributes,
      ai: ai_record(mob.ai),
      no_ai: mob.no_ai,
      motion: %{mob.motion | jump: false, rise: false},
      hurt_by_player: mob.hurt_by_player,
      player_memory: mob.player_memory
    }
    |> then(&if(mob.persistent, do: Map.put(&1, :persistent, true), else: &1))
    |> put_set(:left_handed, mob.left_handed, false)
    |> put_set(:can_pick_up_loot, mob.can_pick_up_loot, false)
    |> put_set(:drop_chances, mob.drop_chances, %{})
    |> put_set(:finalize, mob.finalize, nil)
  end

  defp put_set(record, _key, default, default), do: record
  defp put_set(record, key, value, _default), do: Map.put(record, key, value)

  @doc "A mob of `type` from its record."
  def restore(
        type,
        %{living: %{} = living, equipment: equipment, attributes: attributes} = record
      ) do
    motion = Map.get(record, :motion, %MobMotion{})
    memory = Map.get(record, :player_memory, 0)
    by = Map.get(record, :hurt_by_player)
    persistent = Map.get(record, :persistent, false)
    left_handed = Map.get(record, :left_handed, false)
    loot = Map.get(record, :can_pick_up_loot, false)
    chances = Map.get(record, :drop_chances, %{})
    finalize = Map.get(record, :finalize)

    with true <- valid_equipment?(equipment) and valid_attributes?(attributes),
         true <- MobMotion.valid?(motion),
         ai = Map.get(record, :ai),
         true <- ai == nil or Valimc.AI.Mind.valid?(ai),
         no_ai = Map.get(record, :no_ai, false),
         true <- is_boolean(no_ai),
         true <- is_integer(memory) and memory in 0..@player_memory,
         true <- by == nil or (is_binary(by) and byte_size(by) == 16),
         true <- is_boolean(persistent) and is_boolean(left_handed) and is_boolean(loot),
         true <- valid_chances?(chances) and (finalize == nil or is_atom(finalize)),
         {:ok, restored} <- Living.restore(living),
         {:ok, health} <- Health.restore(living.health, max_health(type, attributes)) do
      {:ok,
       %__MODULE__{
         living: %{restored | health: health},
         equipment: equipment,
         attributes: attributes,
         ai: ai,
         no_ai: no_ai,
         motion: motion,
         hurt_by_player: if(memory > 0, do: by),
         player_memory: memory,
         persistent: persistent,
         left_handed: left_handed,
         can_pick_up_loot: loot,
         drop_chances: chances,
         finalize: finalize
       }}
    else
      _ -> {:error, :invalid_mob}
    end
  end

  def restore(_type, _record), do: {:error, :invalid_mob}

  defp ai_record(%Valimc.AI.Mind{} = mind), do: Valimc.AI.Mind.record(mind)
  defp ai_record(kept), do: kept

  @doc "Whether the mob is alive (`LivingEntity.isAlive`)."
  def alive?(%__MODULE__{living: %{health: %{value: value}}}), do: value > 0

  @doc """
  One tick of its hurt and death timers: `{mob, done}`, `done` once the death
  animation's 20 ticks passed (vanilla `tickDeath`).
  """
  def tick(%__MODULE__{} = mob) do
    # The freezing clock needs the body's environment samples (VMC-015i).
    health = Health.tick(mob.living.health)
    memory = max(0, mob.player_memory - 1)

    {%{
       mob
       | living: %{mob.living | health: health},
         player_memory: memory,
         hurt_by_player: if(memory > 0, do: mob.hurt_by_player)
     }, health.value <= 0 and health.death_ticks >= 20}
  end

  @doc """
  `/kill` (`LivingEntity.kill`: `genericKill` damage of `Float.MAX_VALUE`):
  `{:ok, mob}` dying, or `:ignored` for one already dying.
  """
  def kill(%__MODULE__{} = mob) do
    with {:ok, selected} <- Health.hurt_window(mob.living.health, 3.4028234663852886e38, true),
         {:ok, %{living: living}} <-
           Living.Damage.resolve(mob.living, %{}, selected, :generic_kill) do
      {:ok, %{mob | living: Living.die(living)}}
    else
      _ -> :ignored
    end
  end

  @doc """
  `LivingEntity.hurtServer` on a mob of `type`, up to its death (VMC-037n):
  `hit` holds `:source` (a `Living.DamageSource`), `:amount` and `:attacker`
  (the living entity that caused it, `%{uuid, player}`, or nil). Its
  invulnerabilities, the hurt window and cooldown, armor, toughness and
  enchantment protection from its armor attributes, Resistance and
  absorption. `{:ok, mob, %{full, died}}`: `full` for a hit outside the
  cooldown (the hurt animation, the damage event and knockback), `died` when
  it took its last health. `:ignored` when it takes nothing.
  """
  def hurt(%__MODULE__{} = mob, type, %{source: source, amount: amount} = hit) do
    if not alive?(mob) or immune?(type, source) do
      :ignored
    else
      damage = max(0.0, Float32.round(amount))

      damage =
        if DamageSource.is?(source, :is_freezing) and
             EntityTypes.tag?(type, "freeze_hurts_extra_types"),
           do: Float32.round(damage * 5.0),
           else: damage

      # Helmet wear is the wearer's (`hurtHelmet`), which mobs do not wear.
      damage =
        if DamageSource.is?(source, :damages_helmet) and mob.equipment[:head],
          do: Float32.round(damage * 0.75),
          else: damage

      armor = %{
        armor: value(type, mob, "minecraft:armor"),
        toughness: value(type, mob, "minecraft:armor_toughness")
      }

      with {:ok, selected} <-
             Health.hurt_window(
               mob.living.health,
               damage,
               DamageSource.is?(source, :bypasses_cooldown)
             ),
           {:ok, %{living: living}} <-
             Living.Damage.resolve(mob.living, mob.equipment, selected, source,
               armor: armor,
               infinite: true
             ) do
        attacker = Map.get(hit, :attacker)
        died = living.health.value <= 0

        mob = %{
          mob
          | living: if(died, do: Living.die(living), else: living),
            hurt_by:
              if(attacker && not DamageSource.is?(source, :no_anger),
                do: attacker.uuid,
                else: mob.hurt_by
              )
        }

        mob =
          if attacker && attacker.player,
            do: %{mob | hurt_by_player: attacker.uuid, player_memory: @player_memory},
            else: mob

        {:ok, mob, %{full: selected.notify, died: died}}
      else
        _ -> :ignored
      end
    end
  end

  @doc """
  Whether a hurt of `source` gets past `hurtServer`'s first checks (alive,
  not immune) so that it restarts the mob's idle time even when its damage
  cooldown then turns it away (VMC-043b).
  """
  def stirs?(%__MODULE__{} = mob, type, source), do: alive?(mob) and not immune?(type, source)

  # `isInvulnerableToBase`: fire for fire-immune types, falls for immune ones.
  defp immune?(type, source),
    do:
      (DamageSource.is?(source, :is_fire) and EntityTypes.fetch(type).fire_immune) or
        (DamageSource.is?(source, :is_fall) and EntityTypes.tag?(type, "fall_damage_immune"))

  @doc """
  The value of attribute `name` (`getAttributeValue`): the base, its
  overrides' modifiers and the stock modifiers of the equipment in its slots.
  """
  def value(type, %__MODULE__{} = mob, name) do
    modifiers =
      (get_in(mob.attributes, [name, :modifiers]) || []) ++
        for {slot, stack} <- mob.equipment,
            {^name, id, amount, operation} <- Weapons.modifiers(stack, slot),
            do: {id, amount, operation}

    Attributes.value(name, base(type, mob.attributes, name), modifiers)
  end

  @doc "The value of attribute `name` without its modifiers (the base)."
  def base(type, attributes, name) do
    case attributes do
      %{^name => %{base: base}} when is_float(base) ->
        base

      _ ->
        (EntityTypes.fetch(type).attributes || %{})[name] ||
          Attributes.fetch(plain(name))["default"]
    end
  end

  @doc """
  The attributes vanilla sends a client (the syncable ones the type has), as
  `{id, base, modifiers}` in id order.
  """
  def synced(type, attributes) do
    for {name, _} <- EntityTypes.fetch(type).attributes,
        fact = Attributes.fetch(plain(name)),
        fact["syncable"] do
      modifiers =
        for {id, amount, operation} <- get_in(attributes, [name, :modifiers]) || [],
            do: {id, amount, operation}

      {fact["id"], base(type, attributes, name), modifiers}
    end
    |> Enum.sort()
  end

  @doc "Equipment changes from `previous` to `current`, as `{slot id, stack | nil}`."
  def equipment_changes(current, previous) when current == previous, do: []

  def equipment_changes(current, previous) do
    for {slot, id} <- @slots, not same?(current[slot], previous[slot]), do: {id, current[slot]}
  end

  defp max_health(type, attributes), do: base(type, attributes, "minecraft:max_health")

  defp same?(nil, nil), do: true

  defp same?(%ItemStack{count: count} = a, %ItemStack{count: count} = b),
    do: ItemStack.same_item?(a, b)

  defp same?(_, _), do: false

  defp plain("minecraft:" <> name), do: name

  defp valid_equipment?(equipment) when is_map(equipment),
    do:
      Enum.all?(equipment, fn {slot, stack} ->
        Keyword.has_key?(@slots, slot) and is_struct(stack, ItemStack)
      end)

  defp valid_equipment?(_), do: false

  defp valid_chances?(chances) when is_map(chances),
    do:
      Enum.all?(chances, fn {slot, chance} ->
        Keyword.has_key?(@slots, slot) and is_float(chance) and chance >= 0.0
      end)

  defp valid_chances?(_), do: false

  @doc """
  The drop chance of the equipment in `slot` (`DropChances.byEquipment`): a
  chance above 1 drops it whatever killed the mob, unworn (`isPreserved`).
  """
  def drop_chance(%__MODULE__{drop_chances: chances}, slot),
    do: Map.get(chances, slot, Valimc.Data.HostileFacts.drop_chance())

  @doc "`setDropChance`, kept only where it differs from the default."
  def put_drop_chance(%__MODULE__{drop_chances: chances} = mob, slot, chance) do
    if chance == Valimc.Data.HostileFacts.drop_chance(),
      do: %{mob | drop_chances: Map.delete(chances, slot)},
      else: %{mob | drop_chances: Map.put(chances, slot, chance)}
  end

  defp valid_attributes?(attributes) when is_map(attributes),
    do:
      Enum.all?(attributes, fn
        {"minecraft:" <> _, %{base: base, modifiers: modifiers}} ->
          (base == nil or is_float(base)) and is_list(modifiers)

        _ ->
          false
      end)

  defp valid_attributes?(_), do: false
end
