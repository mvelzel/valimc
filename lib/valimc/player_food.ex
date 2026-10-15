defmodule Valimc.PlayerFood do
  @moduledoc "Player-owned food transitions; the owner commits health effects on its admitted clock."
  alias Valimc.PlayerHealth
  defstruct level: 20, saturation: 5.0, exhaustion: 0.0, timer: 0
  @float_max 3.4028234663852886e38

  # Peaceful recovery adds one while below 20 and can overshoot by a fraction.
  def valid?(%__MODULE__{} = food),
    do:
      is_integer(food.level) and food.level in 0..20 and
        canonical?(food.saturation, 0, 21) and canonical?(food.exhaustion, 0, 40) and
        is_integer(food.timer) and food.timer in 0..80

  def valid?(_), do: false
  def state(player), do: Map.get(player, :food, %__MODULE__{})
  def enough?(%__MODULE__{level: level}), do: level > 6
  def needs?(%__MODULE__{level: level}), do: level < 20

  def exhaust(%__MODULE__{} = food, amount)
      when is_number(amount) and amount >= 0 and amount <= @float_max,
      do: %{food | exhaustion: min(40.0, f32(food.exhaustion + f32(amount)))}

  def eat(%__MODULE__{} = food, nutrition, saturation)
      when is_integer(nutrition) and nutrition in 0..1_000_000 and is_number(saturation) and
             saturation >= 0 and saturation <= @float_max do
    level = min(20, food.level + nutrition)
    # Saturation is the absolute food component value, not the legacy modifier.
    %{food | level: level, saturation: min(level * 1.0, f32(food.saturation + f32(saturation)))}
  end

  def tick(%__MODULE__{} = food, %PlayerHealth{} = health, difficulty, regeneration)
      when difficulty in 0..3 and is_boolean(regeneration) do
    food = spend(food, difficulty)
    injured = health.value > 0 and health.value < health.maximum

    cond do
      regeneration and food.saturation > 0 and injured and food.level >= 20 ->
        advance(food, 10, min(food.saturation, 6.0))

      regeneration and food.level >= 18 and injured ->
        advance(food, 80, 6.0)

      food.level <= 0 ->
        next = food.timer + 1

        if next >= 80 do
          damage =
            if health.value > 10 or difficulty == 3 or (health.value > 1 and difficulty == 2),
              do: 1.0,
              else: 0.0

          {%{food | timer: 0}, %{heal: 0.0, damage: damage}}
        else
          {%{food | timer: next}, %{heal: 0.0, damage: 0.0}}
        end

      true ->
        {%{food | timer: 0}, %{heal: 0.0, damage: 0.0}}
    end
  end

  @doc "Peaceful recovery precedes FoodData's tick; the owner supplies its unsaved body age."
  def peaceful(%__MODULE__{} = food, %PlayerHealth{} = health, difficulty, regeneration, tick)
      when difficulty in 0..3 and is_boolean(regeneration) and is_integer(tick) and tick >= 0 do
    if difficulty == 0 and regeneration do
      twentieth = rem(tick, 20) == 0
      heal = if twentieth and health.value < health.maximum, do: 1.0, else: 0.0

      food =
        if twentieth and food.saturation < 20,
          do: %{food | saturation: f32(food.saturation + 1.0)},
          else: food

      food =
        if rem(tick, 10) == 0 and needs?(food), do: %{food | level: food.level + 1}, else: food

      {food, heal}
    else
      {food, 0.0}
    end
  end

  defp spend(%{exhaustion: exhaustion} = food, difficulty) when exhaustion > 4.0 do
    food = %{food | exhaustion: f32(exhaustion - 4.0)}

    cond do
      food.saturation > 0 -> %{food | saturation: max(0.0, f32(food.saturation - 1.0))}
      difficulty != 0 -> %{food | level: max(0, food.level - 1)}
      true -> food
    end
  end

  defp spend(food, _), do: food

  defp advance(food, threshold, exhaustion) do
    if food.timer + 1 >= threshold,
      do: {%{exhaust(food, exhaustion) | timer: 0}, %{heal: f32(exhaustion / 6.0), damage: 0.0}},
      else: {%{food | timer: food.timer + 1}, %{heal: 0.0, damage: 0.0}}
  end

  defp canonical?(number, lo, hi),
    do: is_number(number) and number >= lo and number <= hi and f32(number) == number

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
