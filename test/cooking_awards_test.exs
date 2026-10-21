defmodule Valimc.CookingAwardsTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingAwards
  @iron "minecraft:iron_ingot_from_smelting_raw_iron"
  @gold "minecraft:gold_ingot_from_smelting_gold_ore"
  @scrap "minecraft:netherite_scrap"

  test "unknown credit, malformed counts and entropy refuse the entire proposal" do
    for uses <- [
          %{"minecraft:missing" => 1},
          %{@iron => 0},
          %{@iron => -1},
          %{@iron => 1.0},
          %{@iron => 2_147_483_648},
          nil,
          []
        ] do
      assert CookingAwards.plan(uses) == {:error, :invalid_cooking_award}
    end

    assert CookingAwards.plan(%{@iron => 1}) == {:error, :missing_award_draw}

    for draws <- [%{@iron => -1}, %{@iron => 16_777_216}, %{@iron => 0.5}, %{@gold => 0}, nil, []] do
      assert CookingAwards.plan(%{@iron => 1}, draws) == {:error, :invalid_cooking_award}
    end

    too_many = Map.new(1..108, &{"minecraft:unknown#{&1}", 1})
    assert CookingAwards.plan(too_many) == {:error, :invalid_cooking_award}
    assert CookingAwards.plan(%{}, too_many) == {:error, :invalid_cooking_award}
  end

  test "unsafe native saturation and aggregate overflow preserve credit by refusal" do
    assert CookingAwards.plan(%{@gold => 2_147_483_647}) == {:error, :experience_limit}
    assert CookingAwards.plan(%{@scrap => 1_073_741_824}) == {:error, :experience_limit}
    uses = %{@gold => 1_073_741_824, @scrap => 536_870_912}
    assert CookingAwards.plan(uses) == {:error, :experience_limit}
  end
end
