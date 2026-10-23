defmodule Valimc.Entity.ItemBurning do
  @moduledoc """
  Fire and lava for a dropped item or experience orb (VMC-034n4d), after its
  kernel tick: `Entity.baseTick`'s burning (a second's damage unless in
  lava, counting down; a fire-immune item stops burning), then the contacts
  of its move in order (`Burning.plan/1`): cactus, fire's ignition and
  damage, lava's ignition and 4 damage, water putting it out, rain putting
  it out (VMC-034n4e), a counter not burning reset to 0. Damage comes
  off its health as `ItemEntity.hurtServer` and `ExperienceOrb.hurtServer`
  take it (an integer, truncated); at 0 or below it is gone and later hurts
  miss it. Fire-immune items (netherite) take no fire damage.
  """
  alias Valimc.Data.Float32
  alias Valimc.Living.Burning

  @doc """
  `{motion, dead, on_fire}` for `motion` (health and fire ticks) after one
  tick: `immune` to fire, `lava` whether it began the tick in lava, `fires`
  its move's contacts (`%{immediate, steps}` as the kernel reports them),
  `rain` a function telling whether it stands in rain where its move ended
  (`isInRain`, asked only of one still burning). `on_fire` is the shared
  flag `baseTick` sets for clients (`setSharedFlagOnFire`): burning after
  its countdown, before the block effects.
  """
  def tick(motion, immune, lava, fires, rain) do
    {:ok, burned} = Burning.tick(motion.fire_ticks, immune, lava)
    {state, gone} = take({%{motion | fire_ticks: burned.ticks}, false}, burned.damage)
    immediate = for {:cactus, amount} <- fires.immediate, do: {:damage, :cactus, amount}

    operations =
      case Burning.plan(fires.steps) do
        {:ok, operations} -> operations
        _ -> []
      end

    # One gone in `baseTick` skips the block effects (`isAffectedByBlocks`).
    if gone do
      {state, true, burned.on_fire}
    else
      {after_effects, gone} =
        Enum.reduce(immediate ++ operations, {state, false}, &apply_contact(&1, &2, immune))

      # Rain puts out what still burns once the effects are applied, even
      # one they just destroyed.
      after_effects =
        if after_effects.fire_ticks > 0 and rain.(),
          do: %{after_effects | fire_ticks: 0},
          else: after_effects

      {settle(after_effects, state, immune), gone, burned.on_fire}
    end
  end

  @doc """
  `hurtServer`'s damage to an item's or orb's `motion`: `{motion, gone}`,
  its health less `damage` as a float, truncated; gone at 0 or below.
  """
  def hurt(motion, damage) do
    health = trunc(Float32.round(motion.health - damage))
    {%{motion | health: health}, health <= 0}
  end

  defp settle(state, before, immune),
    do: %{state | fire_ticks: Burning.settle(state.fire_ticks, before.fire_ticks, immune)}

  # A gone entity's later hurts miss it (`isInvulnerableToBase`: removed).
  defp apply_contact(_operation, {_state, true} = gone, _immune), do: gone

  defp apply_contact(:fire_ignite, {state, gone}, false) do
    {:ok, ignition} = Burning.entity_fire(state.fire_ticks, false, 1.0)
    {%{state | fire_ticks: ignition.ticks}, gone}
  end

  defp apply_contact(:lava_ignite, {state, gone}, false) do
    {:ok, ignition} = Burning.lava(state.fire_ticks, false, 1.0)
    {%{state | fire_ticks: ignition.ticks}, gone}
  end

  defp apply_contact(:lava_hurt, acc, false), do: take(acc, 4.0)
  defp apply_contact({:damage, :cactus, amount}, acc, _immune), do: take(acc, amount)
  defp apply_contact({:damage, _fire, amount}, acc, false), do: take(acc, amount)

  defp apply_contact(:extinguish, {state, gone}, _immune) do
    {:ok, ticks} = Burning.clear(state.fire_ticks)
    {%{state | fire_ticks: ticks}, gone}
  end

  defp apply_contact(_operation, acc, _immune), do: acc

  # `hurtServer`: any hurt that leaves 0 or less discards it.
  defp take({state, gone}, damage) when damage > 0 do
    {state, dead} = hurt(state, damage)
    {state, gone or dead}
  end

  defp take(acc, _damage), do: acc
end
