defmodule Valimc.Living.Burning do
  @moduledoc """
  A living entity's burning counter (vanilla `Entity.remainingFireTicks` with
  `LivingEntity` fire immunity): ignition by fire and lava scaled by the burning
  time attribute, ticking down with damage every second, and the ordered
  fire, lava and extinguish operations of a movement step's contacts. Fresh
  contact, health and persistence belong to the owner.
  """
  alias Valimc.Data.Float32
  @limit 2048
  @kinds [:fire, :soul_fire, :lava, :water, :powder_snow]
  @minimum -2_147_483_648
  @maximum 2_147_483_647
  @float_max 3.4028234663852886e38
  defguardp counter(ticks) when is_integer(ticks) and ticks >= @minimum and ticks <= @maximum
  def valid?(ticks), do: is_integer(ticks) and ticks >= @minimum and ticks <= @maximum

  def assign(ticks, invulnerable) when counter(ticks) and is_boolean(invulnerable),
    do: {:ok, if(invulnerable, do: min(ticks, 1), else: ticks)}

  def assign(_, _), do: {:error, :invalid_burning}

  def clear(ticks) when counter(ticks), do: {:ok, min(0, ticks)}
  def clear(_), do: {:error, :invalid_burning}

  def ignite_ticks(current, ticks, factor, invulnerable \\ false)

  def ignite_ticks(current, ticks, factor, invulnerable)
      when counter(current) and is_integer(ticks) and ticks >= 0 and ticks <= @maximum and
             is_number(factor) and factor >= 0 and factor <= 1024 and is_boolean(invulnerable) do
    scaled = min(@maximum, ceil(ticks * factor))
    next = if scaled > current, do: elem(assign(scaled, invulnerable), 1), else: current
    {:ok, %{ticks: next, clear_freeze: true}}
  end

  def ignite_ticks(_, _, _, _), do: {:error, :invalid_burning}

  def ignite_seconds(current, seconds, factor, invulnerable \\ false)

  def ignite_seconds(current, seconds, factor, invulnerable)
      when counter(current) and is_number(seconds) and seconds >= 0 and seconds <= @float_max do
    product = Float32.round(seconds) * 20.0

    ticks =
      if product >= @maximum, do: @maximum, else: min(@maximum, floor(Float32.round(product)))

    ignite_ticks(current, ticks, factor, invulnerable)
  end

  def ignite_seconds(_, _, _, _), do: {:error, :invalid_burning}

  def tick(ticks, immune, lava, invulnerable \\ false)

  def tick(ticks, immune, lava, invulnerable)
      when counter(ticks) and is_boolean(immune) and is_boolean(lava) and is_boolean(invulnerable) do
    {next, damage} =
      cond do
        ticks <= 0 ->
          {ticks, 0.0}

        immune ->
          {0, 0.0}

        true ->
          {elem(assign(ticks - 1, invulnerable), 1),
           if(rem(ticks, 20) == 0 and not lava, do: 1.0, else: 0.0)}
      end

    {:ok, %{ticks: next, damage: damage, on_fire: next > 0}}
  end

  def tick(_, _, _, _), do: {:error, :invalid_burning}

  def lava(current, immune, factor, invulnerable \\ false)

  def lava(current, immune, factor, invulnerable)
      when counter(current) and is_boolean(immune) and is_number(factor) and factor >= 0 and
             factor <= 1024 and is_boolean(invulnerable) do
    if immune do
      {:ok, %{ticks: current, damage: 0.0, clear_freeze: false}}
    else
      {:ok, ignition} = ignite_seconds(current, 15.0, factor, invulnerable)
      {:ok, Map.put(ignition, :damage, 4.0)}
    end
  end

  def lava(_, _, _, _), do: {:error, :invalid_burning}

  def fire(current, immune, factor, invulnerable \\ false, random \\ fn -> :rand.uniform(2) end)

  def fire(current, immune, factor, invulnerable, random)
      when counter(current) and is_boolean(immune) and is_number(factor) and factor >= 0 and
             factor <= 1024 and is_boolean(invulnerable) and is_function(random, 0) do
    if immune do
      {:ok, %{ticks: current, clear_freeze: false}}
    else
      # Native player contact increments signed counters before the eight-second
      # minimum. Negative cooldowns advance without consuming randomness.
      increment = if current < 0, do: 1, else: random.()

      if increment in 1..2,
        do: fire_step(current, increment, factor, invulnerable),
        else: {:error, :invalid_burning}
    end
  end

  def fire(_, _, _, _, _), do: {:error, :invalid_burning}

  @doc """
  `BaseFireBlock.fireIgnite` for an entity that is not a `ServerPlayer` (a
  mob, an item, an orb): a negative counter steps toward zero, any other
  takes no random step, then eight seconds at least.
  """
  def entity_fire(current, immune, factor)
      when counter(current) and is_boolean(immune) and is_number(factor) and factor >= 0 and
             factor <= 1024 do
    if immune,
      do: {:ok, %{ticks: current, clear_freeze: false}},
      else: fire_step(current, if(current < 0, do: 1, else: 0), factor, false)
  end

  def entity_fire(_, _, _), do: {:error, :invalid_burning}

  defp fire_step(current, increment, factor, invulnerable) do
    wrapped =
      if current + increment > @maximum,
        do: current + increment - 4_294_967_296,
        else: current + increment

    {:ok, next} = assign(wrapped, invulnerable)

    if next >= 0,
      do: ignite_seconds(next, 8.0, factor, invulnerable),
      else: {:ok, %{ticks: next, clear_freeze: false}}
  end

  @doc """
  The end of `applyEffectsFromBlocks` for an entity that is not a player
  (`getFireImmuneTicks` 0): a counter that is not burning and was not raised
  from `before` by this tick's effects goes back to 0.
  """
  def settle(ticks, before, immune)
      when counter(ticks) and counter(before) and is_boolean(immune),
      do: if((ticks > 0 and not immune) or ticks > before, do: ticks, else: 0)

  @doc "Bounded ordered fire and fluid operations from a step's contacts; owners apply them while alive."
  def plan(steps) when is_list(steps) and length(steps) <= @limit do
    with {:ok, _count} <-
           Enum.reduce_while(steps, {:ok, 0}, fn contacts, {:ok, count} ->
             if is_list(contacts) and length(contacts) + count <= @limit and
                  Enum.all?(contacts, &(&1 in @kinds)),
                do: {:cont, {:ok, count + length(contacts)}},
                else: {:halt, {:error, :invalid_fire_contacts}}
           end) do
      {:ok, Enum.flat_map(steps, &step/1)}
    end
  end

  def plan(_), do: {:error, :invalid_fire_contacts}

  defp step(contacts) do
    fire = Enum.filter(contacts, &(&1 in [:fire, :soul_fire]))
    lava = Enum.count(contacts, &(&1 == :lava))

    # Ignitions deduplicate within a movement step; each contacted block retains
    # its damage callback. Extinguishing follows both kinds of ignition.
    if(fire != [] or lava > 0, do: [:clear_freeze], else: []) ++
      if(fire != [],
        do: [
          :fire_ignite | Enum.map(fire, &{:damage, :in_fire, if(&1 == :fire, do: 1.0, else: 2.0)})
        ],
        else: []
      ) ++
      if(lava > 0, do: [:lava_ignite | List.duplicate(:lava_hurt, lava)], else: []) ++
      if(:water in contacts or :powder_snow in contacts, do: [:extinguish], else: [])
  end
end
