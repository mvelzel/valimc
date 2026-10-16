defmodule Valimc.PlayerBurning do
  @moduledoc "Native burning counters and damage requests; fresh contact, health and persistence belong to the player owner."
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
    product = f32(seconds) * 20.0
    ticks = if product >= @maximum, do: @maximum, else: min(@maximum, floor(f32(product)))
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

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
