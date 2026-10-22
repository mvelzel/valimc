defmodule Valimc.Entity.Mob do
  @moduledoc """
  The living part of a mob's record (VMC-043a), as vanilla's `LivingEntity`
  and `Mob` hold it: its living state (`Valimc.Living`: health with its hurt
  and death timers, absorption, effects, fire, air, freezing), its equipment
  by slot, its attribute overrides over the type's defaults, and an AI slot
  that VMC-041a fills (nil until then).

  Attributes are the type's generated defaults (`Valimc.Data.EntityTypes`)
  with `attributes` overriding a base value and adding modifiers, as
  `%{name => %{base: float | nil, modifiers: [{id, amount, operation}]}}`.
  """
  alias Valimc.Data.EntityTypes
  alias Valimc.Living
  alias Valimc.Living.{Attributes, Health}
  alias Valimc.Protocol.ItemStack

  defstruct living: %Living{}, equipment: %{}, attributes: %{}, ai: nil

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
      ai: mob.ai
    }
  end

  @doc "A mob of `type` from its record."
  def restore(
        type,
        %{living: %{} = living, equipment: equipment, attributes: attributes} = record
      ) do
    with true <- valid_equipment?(equipment) and valid_attributes?(attributes),
         {:ok, restored} <- Living.restore(living),
         {:ok, health} <- Health.restore(living.health, max_health(type, attributes)) do
      {:ok,
       %__MODULE__{
         living: %{restored | health: health},
         equipment: equipment,
         attributes: attributes,
         ai: Map.get(record, :ai)
       }}
    else
      _ -> {:error, :invalid_mob}
    end
  end

  def restore(_type, _record), do: {:error, :invalid_mob}

  @doc "Whether the mob is alive (`LivingEntity.isAlive`)."
  def alive?(%__MODULE__{living: %{health: %{value: value}}}), do: value > 0

  @doc """
  One tick of its hurt and death timers: `{mob, done}`, `done` once the death
  animation's 20 ticks passed (vanilla `tickDeath`).
  """
  def tick(%__MODULE__{} = mob) do
    # The freezing clock needs the body's environment samples (VMC-015i).
    health = Health.tick(mob.living.health)

    {%{mob | living: %{mob.living | health: health}},
     health.value <= 0 and health.death_ticks >= 20}
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
