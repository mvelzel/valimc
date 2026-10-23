defmodule Valimc.Entity.EffectCloud do
  @moduledoc """
  An area effect cloud (VMC-037o): the dragon's breath a dragon fireball
  leaves (`DragonFireball.onHit`), as vanilla's `AreaEffectCloud` ticks it.
  It waits 20 ticks, then lasts 600, its radius growing from 3 to 7; every
  5 ticks each living entity standing within its radius (and its half-block
  high box) that it has not touched in the last 20 ticks takes its effect,
  Instant Damage II at half strength: 6 damage (`indirect_magic`, the cloud
  dealing it for its owner), and an undead mob is healed 4 instead.
  """
  alias Valimc.Data.{EffectTypes, EntityTypes, Float32}
  alias Valimc.Entity.Body

  @type_name "minecraft:area_effect_cloud"

  @doc "The cloud's type."
  def type, do: @type_name

  @doc "Its data and defaults (`AreaEffectCloud`'s fields)."
  def data do
    %{
      owner: nil,
      age: 0,
      radius: 3.0,
      radius_per_tick: 0.0,
      duration: 600,
      wait: 20,
      reapplication: 20,
      effects: [],
      victims: %{},
      particle: nil,
      waiting: false
    }
  end

  @doc "A dragon's breath cloud from `owner` (`%{uuid, id, player}` or nil)."
  def dragon_breath(owner) do
    {:ok, body} = Body.new(@type_name)
    radius = 3.0
    duration = 600

    %{
      body
      | data: %{
          body.data
          | owner: owner,
            radius: radius,
            duration: duration,
            radius_per_tick: Float32.round((7.0 - radius) / duration),
            effects: [{EffectTypes.id("instant_damage"), 1}],
            particle: {Valimc.Protocol.CombatPackets.particle_id("minecraft:dragon_breath"), 1.0}
        }
    }
  end

  @doc "Its entity data values (`Body.values/1`)."
  def values(%Body{data: d}) do
    [
      {:cloud_radius, d.radius, 3.0},
      {:cloud_waiting, d.waiting, false},
      {:cloud_particle, d.particle, nil}
    ]
  end

  @doc "The cloud's box at `{x, y, z}`: its radius across, half a block high."
  def box(%Body{data: d}, {x, y, z}) do
    half = Float32.round(d.radius * 2.0) / 2
    {x - half, y, z - half, x + half, y + 0.5, z + half}
  end

  @doc """
  One tick (`serverTick`) of the cloud at `position` over the living
  entities `living` (`%{ref, uuid, position, box, type}`): `{:keep, body,
  effects}` or `:remove`, effects `{:hurt, target, amount}` and `{:heal,
  target, amount}`.
  """
  def tick(%Body{data: d} = body, position, living) do
    age = d.age + 1

    cond do
      d.duration != -1 and age - d.wait >= d.duration ->
        :remove

      age < d.wait ->
        {:keep, %{body | data: %{d | age: age, waiting: true}}, []}

      true ->
        radius = Float32.round(d.radius + d.radius_per_tick)

        if radius < 0.5 do
          :remove
        else
          d = %{d | age: age, waiting: false, radius: radius}
          body = %{body | data: d}
          if rem(age, 5) == 0, do: apply_effects(body, position, living), else: {:keep, body, []}
        end
    end
  end

  defp apply_effects(%Body{data: d} = body, {x, _, z} = position, living) do
    victims = Map.reject(d.victims, fn {_, until} -> d.age >= until end)
    {bx0, by0, bz0, bx1, by1, bz1} = box(body, position)
    radius = d.radius

    {victims, effects} =
      Enum.reduce(living, {victims, []}, fn target, {victims, effects} ->
        {tx0, ty0, tz0, tx1, ty1, tz1} = target.box
        {tx, _, tz} = target.position
        inside = tx0 < bx1 and tx1 > bx0 and ty0 < by1 and ty1 > by0 and tz0 < bz1 and tz1 > bz0
        dist = (tx - x) * (tx - x) + (tz - z) * (tz - z)

        if inside and not Map.has_key?(victims, target.uuid) and dist <= radius * radius do
          hits = for {id, amplifier} <- d.effects, do: instant(target, id, amplifier)
          {Map.put(victims, target.uuid, d.age + d.reapplication), effects ++ hits}
        else
          {victims, effects}
        end
      end)

    {:keep, %{body | data: %{d | victims: victims}}, effects}
  end

  # `HealOrHarmMobEffect.applyInstantaneousEffect` at half strength.
  defp instant(target, id, amplifier) do
    harm = id == EffectTypes.id("instant_damage")

    inverted =
      target.type != "minecraft:player" and
        EntityTypes.tag?(target.type, "inverted_healing_and_harm")

    if harm != inverted,
      do: {:hurt, target, trunc(0.5 * Bitwise.bsl(6, amplifier) + 0.5) * 1.0},
      else: {:heal, target, trunc(0.5 * Bitwise.bsl(4, amplifier) + 0.5) * 1.0}
  end
end
