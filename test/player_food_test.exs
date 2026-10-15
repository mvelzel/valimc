defmodule Valimc.PlayerFoodTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerFood, PlayerHealth}

  test "exhaustion spends one step per admitted tick and only strictly above four" do
    food = %PlayerFood{level: 18, saturation: 0.5, exhaustion: 40.0}
    {first, _} = PlayerFood.tick(food, %PlayerHealth{}, 1, true)
    assert first.saturation == 0.0 and first.level == 18 and first.exhaustion == 36.0
    {second, _} = PlayerFood.tick(first, %PlayerHealth{}, 1, true)
    assert second.level == 17 and second.exhaustion == 32.0
    exact = %{food | exhaustion: 4.0}

    assert PlayerFood.tick(exact, %PlayerHealth{}, 1, true) ==
             {exact, %{heal: 0.0, damage: 0.0}}

    assert PlayerFood.exhaust(food, 40).exhaustion == 40.0
  end

  test "healing spends saturation through exhaustion and the native float32 fraction" do
    food = %PlayerFood{timer: 9}
    {next, effect} = PlayerFood.tick(food, %PlayerHealth{value: 10.0}, 1, true)
    assert effect == %{heal: 0.8333333134651184, damage: 0.0}
    assert next.timer == 0 and next.exhaustion == 5.0 and next.saturation == 5.0
    {spent, _} = PlayerFood.tick(next, %PlayerHealth{value: 10.0}, 1, true)
    assert spent.exhaustion == 1.0 and spent.saturation == 4.0 and spent.timer == 1

    assert {%{timer: 0}, %{heal: +0.0}} =
             PlayerFood.tick(food, %PlayerHealth{value: 10.0}, 1, false)
  end

  test "starvation floors depend on difficulty and stay active when regeneration is disabled" do
    food = %PlayerFood{level: 0, saturation: 0.0, timer: 79}

    for {difficulty, health, damage} <- [
          {1, 10.0, 0.0},
          {1, 11.0, 1.0},
          {2, 1.0, 0.0},
          {2, 2.0, 1.0},
          {3, 1.0, 1.0}
        ] do
      assert {%{timer: 0}, %{heal: +0.0, damage: ^damage}} =
               PlayerFood.tick(food, %PlayerHealth{value: health}, difficulty, false)
    end
  end

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
end
