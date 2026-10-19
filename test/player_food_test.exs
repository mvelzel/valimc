defmodule Valimc.PlayerFoodTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerFood, PlayerHealth}

  test "peaceful recovery restores food independently and permits native fractional saturation overshoot" do
    food = %PlayerFood{level: 19, saturation: 19.5}
    health = %PlayerHealth{value: 10.0}
    assert PlayerFood.peaceful(food, health, 0, false, 20) == {food, 0.0}
    assert PlayerFood.peaceful(food, health, 0, true, 10) == {%{food | level: 20}, 0.0}
    {next, heal} = PlayerFood.peaceful(food, health, 0, true, 20)
    assert next.level == 20 and next.saturation == 20.5 and heal == 1.0
    assert PlayerFood.valid?(next)
    assert PlayerFood.eat(next, 0, 0).saturation == 20.0
  end

  test "bounded canonical state excludes damaged persistence and supports native eligibility" do
    assert PlayerFood.valid?(%PlayerFood{})
    assert PlayerFood.enough?(%PlayerFood{level: 7})
    refute PlayerFood.enough?(%PlayerFood{level: 6})
    assert PlayerFood.needs?(%PlayerFood{level: 19})
    refute PlayerFood.needs?(%PlayerFood{})

    for {key, value} <- [
          level: -1,
          level: 21,
          saturation: -1.0,
          saturation: 21.1,
          saturation: 0.1,
          exhaustion: 40.1,
          exhaustion: -1.0,
          timer: -1,
          timer: 81
        ],
        do: refute(PlayerFood.valid?(Map.put(%PlayerFood{}, key, value)))
  end

  test "idle eligibility preserves peaceful boundaries and never skips pending consequences" do
    health = %PlayerHealth{}
    for phase <- 1..19, do: assert(PlayerFood.idle?(%PlayerFood{}, health, phase))
    refute PlayerFood.idle?(%PlayerFood{}, health, 0)
    refute PlayerFood.idle?(%PlayerFood{level: 19}, health, 10)
    assert PlayerFood.idle?(%PlayerFood{level: 19}, health, 9)

    for food <- [%PlayerFood{level: 0}, %PlayerFood{exhaustion: 4.125}, %PlayerFood{timer: 1}],
        do: refute(PlayerFood.idle?(food, health, 1))

    refute PlayerFood.idle?(%PlayerFood{}, %PlayerHealth{value: 19.0}, 1)
    assert PlayerFood.idle?(%PlayerFood{exhaustion: 4.0}, health, 1)
  end
end
