defmodule Valimc.Entity.MobVitals do
  @moduledoc """
  A mob's living rules after its kernel tick (VMC-015i), the player's rules
  over a mob's state: landing damage (`Block.fallOn` and
  `calculateFallDamage`), the fire, lava and water contacts of its move in
  order (`Burning.plan/1`), burning down a second at a time, and air with
  drowning for a type that cannot breathe under water. Each hurt goes
  through the one hurt path (`Valimc.Entity.Combat.hurt_mob/4`), so a mob
  dies, and drops, as any other death.
  Returns the body and its entity events.
  """
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.Mob
  alias Valimc.Living.{Air, Attributes, Burning, FallDamage, Landing}
  alias Valimc.Protocol.Registries

  @doc "Apply kernel tick `ticked` (its landing, contacts and eye) to `body` of `type`."
  def apply(type, body, ticked) do
    facts = EntityTypes.fetch(type)
    {mob, events} = {body.mob, []}
    {mob, events} = landing(type, mob, events, ticked.landing)
    {mob, events} = contacts(type, facts, mob, events, ticked.fire_contacts)
    {mob, events} = burn(type, facts, mob, events, ticked.lava)
    {mob, events} = breathe(type, mob, events, ticked)
    {%{body | mob: mob}, events}
  end

  defp landing(_type, mob, events, nil), do: {mob, events}

  defp landing(type, mob, events, {state, distance}) do
    {:ok, call} = Landing.call(state, distance, false)

    if call == nil or tagged?(type, "minecraft:fall_damage_immune") do
      {mob, events}
    else
      {:ok, jump} = Attributes.jump_boost(mob.living.effects)
      safe = Mob.base(type, mob.attributes, "minecraft:safe_fall_distance")

      {:ok, amount} =
        FallDamage.calculate(call.distance, call.multiplier, %FallDamage{
          safe_distance: safe + jump.safe_distance - 3.0,
          attribute_multiplier: Mob.base(type, mob.attributes, "minecraft:fall_damage_multiplier")
        })

      if amount > 0, do: hurt(type, mob, events, call.source, amount * 1.0), else: {mob, events}
    end
  end

  defp contacts(type, facts, mob, events, fires) do
    with {:ok, operations} <- Burning.plan(fires.steps) do
      immediate = for {source, amount} <- fires.immediate, do: {:damage, source, amount}

      Enum.reduce(immediate ++ operations, {mob, events}, fn operation, {mob, events} ->
        if Mob.alive?(mob),
          do: contact(type, facts, mob, events, operation),
          else: {mob, events}
      end)
    else
      _ -> {mob, events}
    end
  end

  defp contact(type, facts, mob, events, :fire_ignite) do
    {:ok, ignition} =
      Burning.fire(mob.living.fire_ticks, facts.fire_immune, burning(type, mob))

    {put_fire(mob, ignition.ticks), events}
  end

  defp contact(type, facts, mob, events, :lava_ignite) do
    {:ok, ignition} = Burning.lava(mob.living.fire_ticks, facts.fire_immune, burning(type, mob))
    {put_fire(mob, ignition.ticks), events}
  end

  defp contact(type, facts, mob, events, :lava_hurt) do
    if facts.fire_immune, do: {mob, events}, else: hurt(type, mob, events, :lava, 4.0)
  end

  defp contact(type, _facts, mob, events, {:damage, source, amount}),
    do: hurt(type, mob, events, source, amount * 1.0)

  defp contact(_type, _facts, mob, events, :extinguish) do
    {:ok, ticks} = Burning.clear(mob.living.fire_ticks)
    {put_fire(mob, ticks), events}
  end

  defp contact(_type, _facts, mob, events, :clear_freeze) do
    freezing = mob.living.freezing
    {%{mob | living: %{mob.living | freezing: %{freezing | frozen_ticks: 0}}}, events}
  end

  defp contact(_type, _facts, mob, events, _operation), do: {mob, events}

  # `Entity.baseTick`'s burning: a second's damage (not in lava), counting down.
  defp burn(type, facts, mob, events, lava) do
    {:ok, burned} = Burning.tick(mob.living.fire_ticks, facts.fire_immune, lava)
    mob = put_fire(mob, burned.ticks)

    if burned.damage > 0,
      do: hurt(type, mob, events, :on_fire, burned.damage),
      else: {mob, events}
  end

  # `LivingEntity.baseTick`'s air: a type that breathes under water keeps it.
  defp breathe(type, mob, events, ticked) do
    submerged = Air.submerged?(ticked.eye_water, ticked.eye_state)
    effects = mob.living.effects

    breathes =
      tagged?(type, "minecraft:can_breathe_under_water") or
        Valimc.Data.SpawnFacts.water_breather?(type)

    oxygen = Mob.base(type, mob.attributes, "minecraft:oxygen_bonus")
    draw = if oxygen > 0 and submerged, do: :rand.uniform_real(), else: 0.0
    policy = if breathes, do: :hold, else: Air.policy(effects)
    {air, damage} = Air.tick(mob.living.air_supply, submerged, false, oxygen, draw, policy)
    mob = %{mob | living: %{mob.living | air_supply: air}}
    if damage > 0, do: hurt(type, mob, events, :drown, damage), else: {mob, events}
  end

  defp hurt(type, mob, events, source, amount) do
    {mob, more} = Valimc.Entity.Combat.hurt_mob(type, mob, source, amount)
    {mob, events ++ more}
  end

  defp put_fire(mob, ticks), do: %{mob | living: %{mob.living | fire_ticks: ticks}}

  defp burning(type, mob), do: Mob.base(type, mob.attributes, "minecraft:burning_time")

  defp tagged?(type, tag),
    do: EntityTypes.id(type) in (Registries.tag("minecraft:entity_type", tag) || [])
end
