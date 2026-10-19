defmodule Valimc.CookingAwardsTest do
  use ExUnit.Case, async: true
  alias Valimc.{CookingAwards, CookingRecipes}
  @iron "minecraft:iron_ingot_from_smelting_raw_iron"
  @stone "minecraft:smooth_stone"
  @gold "minecraft:gold_ingot_from_smelting_gold_ore"
  @scrap "minecraft:netherite_scrap"

  test "fractional credit rounds strictly below the supplied native nextFloat sample" do
    assert {:ok, low} = CookingAwards.plan(%{@stone => 5}, %{@stone => 8_388_607})
    assert {:ok, tie} = CookingAwards.plan(%{@stone => 5}, %{@stone => 8_388_608})
    assert low.experience == 1 and tie.experience == 0
    assert tie.recipes == [%{recipe: @stone, uses: 5, experience: 0}]
    assert tie.draws_used == %{@stone => 8_388_608}

    assert {:ok, up} = CookingAwards.plan(%{@iron => 7}, %{@iron => 0})
    assert {:ok, down} = CookingAwards.plan(%{@iron => 7}, %{@iron => 16_777_215})
    assert up.experience == 5 and down.experience == 4
    assert up == elem(CookingAwards.plan(%{@iron => 7}, %{@iron => 0}), 1)
  end

  test "mixed recipe uses are all awarded in stable order, including zero-XP outcomes" do
    uses = %{@iron => 4, @gold => 2, @stone => 1}
    assert {:ok, plan} = CookingAwards.plan(uses, %{@iron => 0, @stone => 16_777_215})
    assert plan.experience == 5
    assert Enum.map(plan.recipes, & &1.recipe) == Enum.sort(Map.keys(uses))
    assert Map.new(plan.recipes, &{&1.recipe, &1.uses}) == uses
    assert Enum.map(plan.recipes, & &1.experience) == [2, 3, 0]
    assert plan.draws_used == %{@iron => 0, @stone => 16_777_215}
  end

  test "integral products and empty credit consume no random sample" do
    for {uses, draws, amount} <- [
          {%{@gold => 8}, %{}, 8},
          {%{@stone => 10}, %{}, 1},
          {%{@gold => 8}, %{@gold => 1}, 8}
        ] do
      assert {:ok, plan} = CookingAwards.plan(uses, draws)
      assert plan.experience == amount and plan.draws_used == %{}
    end

    assert CookingAwards.plan(%{}) == {:ok, %{experience: 0, recipes: [], draws_used: %{}}}
  end

  test "count conversion and multiplication preserve native float32 precision" do
    # The odd count first rounds to 16,777,216 at Java's i2f conversion.
    assert {:ok, plan} = CookingAwards.plan(%{@gold => 16_777_217})
    assert plan.experience == 16_777_216
    assert plan.recipes == [%{recipe: @gold, uses: 16_777_217, experience: 16_777_216}]
    assert {:ok, near} = CookingAwards.plan(%{@gold => 2_147_483_583})
    assert near.experience == 2_147_483_520
  end

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

  test "every persisted stock recipe identity resolves independently of current input" do
    facts = JSON.decode!(File.read!("priv/crafting/cooking.json"))
    assert length(facts["recipes"]) == 107

    for row <- facts["recipes"] do
      assert {:ok, xp} = CookingRecipes.experience(row["recipe"])
      assert <<xp::float-32>> == <<row["xp_bits"]::unsigned-32>>
      assert {:ok, _} = CookingAwards.plan(%{row["recipe"] => 1}, %{row["recipe"] => 0})
    end

    assert :error = CookingRecipes.experience("minecraft:missing")
  end
end
