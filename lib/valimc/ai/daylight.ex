defmodule Valimc.AI.Daylight do
  @moduledoc """
  The sun on undead mobs (VMC-043b, `Mob.burnUndead` after the move, for
  types tagged `burn_in_daylight`) and rain on burning ones
  (`applyEffectsFromBlocks`' `isInRain`).

  While monsters burn (the overworld day's `monsters_burn`), a mob whose
  eyes are in light above half brightness draws from its random whether
  the sun takes it this tick (more likely the brighter it is), unless it is
  in water or rain or cannot see the sky. A helmet takes the wear instead
  (0 or 1 points, drawn too); a bare head catches fire for eight seconds.
  Rain puts out a burning mob first.
  """
  alias Valimc.AI.{Mind, Random, World}
  alias Valimc.Data.{EntityTypes, Float32}
  alias Valimc.Entity.{Body, Mob}
  alias Valimc.Living.Durability

  @break_head 49

  @doc """
  The sun's and rain's part of `body`'s tick at `{x, y, z}` (after its
  move) over `world`: `{body, events}`.
  """
  def tick(%Body{mob: %Mob{} = mob} = body, position, %World{} = world) do
    if Mob.alive?(mob) do
      {body, events} = rain(body, position, world)
      burn(body, position, world, events)
    else
      {body, []}
    end
  end

  def tick(body, _position, _world), do: {body, []}

  # `clearFire` (its hiss is not played yet).
  defp rain(%Body{mob: mob} = body, position, world) do
    if mob.living.fire_ticks > 0 and raining?(body, position, world),
      do: {put_fire(body, 0), []},
      else: {body, []}
  end

  defp raining?(_body, _position, %World{rain: nil}), do: false

  defp raining?(body, {x, y, z}, %World{rain: rain}) do
    {_, height, _} = Body.dimensions(body)
    rain.({x, y, z}, y + height)
  end

  defp burn(%Body{type: type, mob: mob} = body, {x, y, z} = position, world, events) do
    if world.monsters_burn and EntityTypes.tag?(type, "burn_in_daylight") do
      {_, _, eye} = Body.dimensions(body)
      at = {floor(x), floor(y + eye), floor(z)}
      brightness = World.light(world, at)

      if brightness > 0.5 do
        {f, body} = float(body)

        burns =
          Float32.round(f * 30.0) < Float32.round(Float32.round(brightness - 0.4) * 2.0) and
            mob.motion.water <= 0.0 and not raining?(body, position, world) and
            World.sees_sky?(world, at)

        if burns, do: sun(body, events), else: {body, events}
      else
        {body, events}
      end
    else
      {body, events}
    end
  end

  # A helmet wears (`hurtAndBreak` of 0 or 1), else the mob catches fire for
  # eight seconds (`igniteForSeconds`, scaled by its burning time).
  defp sun(%Body{mob: mob} = body, events) do
    case mob.equipment[:head] do
      nil ->
        ticks = ceil(160 * Mob.value(body.type, mob, "minecraft:burning_time"))

        {if(mob.living.fire_ticks < ticks, do: put_fire(body, ticks), else: body), events}

      helmet ->
        {n, body} = int(body, 2)

        case Durability.hurt_and_break(helmet, n, false) do
          {nil, _broken} ->
            equipment = Map.delete(mob.equipment, :head)
            {%{body | mob: %{body.mob | equipment: equipment}}, events ++ [{:event, @break_head}]}

          {stack, _} ->
            {%{body | mob: %{body.mob | equipment: Map.put(mob.equipment, :head, stack)}}, events}
        end
    end
  end

  defp put_fire(%Body{mob: mob} = body, ticks),
    do: %{body | mob: %{mob | living: %{mob.living | fire_ticks: ticks}}}

  defp float(body), do: draw(body, &Random.float/1, fn -> :rand.uniform() end)

  defp int(body, bound),
    do: draw(body, &Random.int(&1, bound), fn -> :rand.uniform(bound) - 1 end)

  # The mob's own random where it thinks.
  defp draw(%Body{mob: %Mob{ai: %Mind{random: random} = mind} = mob} = body, fun, _fallback) do
    {value, random} = fun.(random)
    {value, %{body | mob: %{mob | ai: %{mind | random: random}}}}
  end

  defp draw(body, _fun, fallback), do: {fallback.(), body}
end
