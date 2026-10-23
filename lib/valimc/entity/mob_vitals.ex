defmodule Valimc.Entity.MobVitals do
  @moduledoc """
  A mob's living rules after its kernel tick (VMC-015i), the player's rules
  over a mob's state, in vanilla's tick order: `baseTick`'s burning down a
  second at a time and air with drowning for a type that cannot breathe
  under water, then its move's landing damage (`Block.fallOn` and
  `calculateFallDamage`) and the fire, lava and water contacts of the move
  in order (`Burning.plan/1`, `applyEffectsFromBlocks`), and last water's
  hurt to a type sensitive to it (a blaze, VMC-043d; rain is not read yet).
  Each hurt goes
  through the one hurt path (`Valimc.Entity.Combat.hurt_mob/4`), so a mob
  dies, and drops, as any other death.
  Returns the body and its entity events.
  """
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.Mob
  alias Valimc.Living.{Air, Attributes, Burning, FallDamage, Landing}
  alias Valimc.Protocol.Registries

  @water_sensitive ["minecraft:blaze"]

  @doc """
  `baseTick`'s burning, before the mob thinks (VMC-043b: its hurt sound and
  idle reset come before its goals, as vanilla's): a second's damage while
  burning outside lava (the lava its last move left), counting down.
  `{body, events}`.
  """
  def base_tick(type, %{mob: %Mob{} = mob} = body) do
    if Mob.alive?(mob) do
      kind = %{type: type, data: body.data}
      {mob, events} = burn(kind, EntityTypes.fetch(type), mob, [], mob.motion.lava > 0.0)
      {%{body | mob: mob, data: Valimc.Entity.Animal.hurt_if(type, body, mob)}, events}
    else
      {body, []}
    end
  end

  @doc "Apply kernel tick `ticked` (its landing, contacts and eye) to `body` of `type`."
  def apply(type, body, ticked) do
    facts = EntityTypes.fetch(type)
    # Hurts read the body's data (an animal's age for its voice).
    kind = %{type: type, data: body.data}
    {mob, events} = {body.mob, []}
    {mob, events} = breathe(kind, mob, events, ticked)
    {mob, events} = landing(kind, mob, events, ticked.landing)
    {mob, events} = contacts(kind, facts, mob, events, ticked.fire_contacts)
    {mob, events} = wet(kind, mob, events, ticked.water)
    {%{body | mob: mob, data: Valimc.Entity.Animal.hurt_if(type, body, mob)}, events}
  end

  defp landing(_kind, mob, events, nil), do: {mob, events}

  defp landing(kind, mob, events, {state, distance}) do
    {:ok, call} = Landing.call(state, distance, false)

    if call == nil or tagged?(kind.type, "minecraft:fall_damage_immune") do
      {mob, events}
    else
      {:ok, jump} = Attributes.jump_boost(mob.living.effects)
      safe = Mob.base(kind.type, mob.attributes, "minecraft:safe_fall_distance")

      {:ok, amount} =
        FallDamage.calculate(call.distance, call.multiplier, %FallDamage{
          safe_distance: safe + jump.safe_distance - 3.0,
          attribute_multiplier:
            Mob.base(kind.type, mob.attributes, "minecraft:fall_damage_multiplier")
        })

      if amount > 0, do: hurt(kind, mob, events, call.source, amount * 1.0), else: {mob, events}
    end
  end

  defp contacts(kind, facts, mob, events, fires) do
    with {:ok, operations} <- Burning.plan(fires.steps) do
      immediate = for {source, amount} <- fires.immediate, do: {:damage, source, amount}
      before = mob.living.fire_ticks

      {mob, events} =
        Enum.reduce(immediate ++ operations, {mob, events}, fn operation, {mob, events} ->
          if Mob.alive?(mob),
            do: contact(kind, facts, mob, events, operation),
            else: {mob, events}
        end)

      {put_fire(mob, Burning.settle(mob.living.fire_ticks, before, facts.fire_immune)), events}
    else
      _ -> {mob, events}
    end
  end

  defp contact(kind, facts, mob, events, :fire_ignite) do
    {:ok, ignition} =
      Burning.entity_fire(mob.living.fire_ticks, facts.fire_immune, burning(kind, mob))

    {put_fire(mob, ignition.ticks), events}
  end

  defp contact(kind, facts, mob, events, :lava_ignite) do
    {:ok, ignition} = Burning.lava(mob.living.fire_ticks, facts.fire_immune, burning(kind, mob))
    {put_fire(mob, ignition.ticks), events}
  end

  defp contact(kind, facts, mob, events, :lava_hurt) do
    if facts.fire_immune, do: {mob, events}, else: hurt(kind, mob, events, :lava, 4.0)
  end

  defp contact(kind, _facts, mob, events, {:damage, source, amount}),
    do: hurt(kind, mob, events, source, amount * 1.0)

  defp contact(_kind, _facts, mob, events, :extinguish) do
    {:ok, ticks} = Burning.clear(mob.living.fire_ticks)
    {put_fire(mob, ticks), events}
  end

  defp contact(_kind, _facts, mob, events, :clear_freeze) do
    freezing = mob.living.freezing
    {%{mob | living: %{mob.living | freezing: %{freezing | frozen_ticks: 0}}}, events}
  end

  defp contact(_kind, _facts, mob, events, _operation), do: {mob, events}

  # `Entity.baseTick`'s burning: a second's damage (not in lava), counting down.
  defp burn(kind, facts, mob, events, lava) do
    {:ok, burned} = Burning.tick(mob.living.fire_ticks, facts.fire_immune, lava)
    mob = put_fire(mob, burned.ticks)

    if burned.damage > 0,
      do: hurt(kind, mob, events, :on_fire, burned.damage),
      else: {mob, events}
  end

  # `LivingEntity.baseTick`'s air: a type that breathes under water keeps it.
  defp breathe(kind, mob, events, ticked) do
    submerged = Air.submerged?(ticked.eye_water, ticked.eye_state)
    effects = mob.living.effects

    breathes =
      tagged?(kind.type, "minecraft:can_breathe_under_water") or
        Valimc.Data.SpawnFacts.water_breather?(kind.type)

    oxygen = Mob.base(kind.type, mob.attributes, "minecraft:oxygen_bonus")
    draw = if oxygen > 0 and submerged, do: :rand.uniform_real(), else: 0.0
    policy = if breathes, do: :hold, else: Air.policy(effects)
    {air, damage} = Air.tick(mob.living.air_supply, submerged, false, oxygen, draw, policy)
    mob = %{mob | living: %{mob.living | air_supply: air}}
    if damage > 0, do: hurt(kind, mob, events, :drown, damage), else: {mob, events}
  end

  # `aiStep`'s `isSensitiveToWater() && isInWaterOrRain()`: drowning, 1.
  defp wet(%{type: type} = kind, mob, events, true) when type in @water_sensitive,
    do: if(Mob.alive?(mob), do: hurt(kind, mob, events, :drown, 1.0), else: {mob, events})

  defp wet(_kind, mob, events, _water), do: {mob, events}

  defp hurt(%{type: type, data: data}, mob, events, source, amount) do
    {mob, more, _} = Valimc.Entity.Combat.hurt_mob(type, mob, source, amount, data)
    {mob, events ++ more}
  end

  defp put_fire(mob, ticks), do: %{mob | living: %{mob.living | fire_ticks: ticks}}

  defp burning(%{type: type}, mob), do: Mob.base(type, mob.attributes, "minecraft:burning_time")

  defp tagged?(type, tag),
    do: EntityTypes.id(type) in (Registries.tag("minecraft:entity_type", tag) || [])
end
