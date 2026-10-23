defmodule Valimc.MiningTest do
  # Hardness, tool speeds, submersion, loot and attempt timing are compared by the
  # mining, mining_tool, player_mining, block_loot and mining_attempt oracle
  # stages; these tests cover ValiMC's own boundaries and break code.
  use ExUnit.Case, async: true
  alias Valimc.Player.MiningAttempt
  alias Valimc.Blocks.Mining
  alias Valimc.Blocks.{Breaking, MiningLoot}
  alias Valimc.Data.Blocks
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}

  # The attempt still holds `token` and has not ended.
  defp current?(attempt, token),
    do: attempt.token == token and attempt.phase in [:active, :finishing, :ready]

  test "progress thresholds hold and malformed inputs are explicit errors" do
    {:ok, rate} = Mining.rate(Data.block("stone"), 1, true)
    assert {:ok, %{complete: false, stoppable: true}} = Mining.advance(rate, 31)
    assert {:ok, %{complete: true}} = Mining.advance(rate, 44)

    for args <- [{1, -1, true}, {1, 1, nil}],
        do: assert(apply(Mining, :rate, Tuple.to_list(args)) == {:error, :invalid_mining_input})

    assert {:error, :invalid_mining_input} = Mining.advance(rate, -1)
  end

  defp plan(name, properties \\ %{}, tool \\ nil, harvest \\ true, around \\ %{}),
    do: Breaking.plan(Blocks.state(name, properties), {0, 64, 0}, tool, harvest, around)

  defp enchanted(item, enchantments),
    do: %{ItemStack.new(item) | components: %{"minecraft:enchantments" => enchantments}}

  defp items(stacks), do: Enum.map(stacks, &{ItemTypes.item(&1.item_id)["name"], &1.count})

  test "breaks drop their tables' loot and experience, none without the right tool" do
    ore = Blocks.default_state("diamond_ore")
    fortune = enchanted("diamond_pickaxe", %{"minecraft:fortune" => 3})
    %{drops: [diamonds], experience: xp} = plan("diamond_ore", %{}, fortune)
    assert diamonds.item_id == ItemTypes.id("diamond") and diamonds.count in 1..4 and xp in 3..7
    silk = enchanted("diamond_pickaxe", %{"minecraft:silk_touch" => 1})
    assert %{drops: [%{item_id: item}], experience: 0} = plan("diamond_ore", %{}, silk)
    assert item == ItemTypes.id("diamond_ore")

    assert %{drops: [], experience: 0, writes: %{{0, 64, 0} => {^ore, 0}}} =
             plan("diamond_ore", %{}, nil, false)

    assert {:ok, []} = MiningLoot.drops(Blocks.default_state("air"), {0, 64, 0})
  end

  test "a tall plant drops with the player's tool whether harvested or not, reading its other half" do
    upper = Blocks.state("tall_grass", %{"half" => "upper"})

    assert %{drops: drops} =
             plan("tall_grass", %{"half" => "lower"}, ItemStack.new("shears"), false, %{
               above: upper
             })

    assert items(drops) == [{"minecraft:short_grass", 2}]

    # Its upper half gone, the lower one drops nothing.
    assert %{drops: []} = plan("tall_grass", %{"half" => "lower"}, ItemStack.new("shears"))
  end

  test "a door's upper half without its tool takes the lower half without drops" do
    lower = Blocks.state("iron_door", %{"half" => "lower"})

    assert %{writes: writes, drops: []} =
             plan("iron_door", %{"half" => "upper"}, nil, false, %{below: lower})

    assert writes[{0, 63, 0}] == {lower, 0}
    # With its tool the block rules break the lower half, which drops the door.
    assert %{writes: writes} =
             plan("iron_door", %{"half" => "upper"}, ItemStack.new("iron_pickaxe"), true, %{
               below: lower
             })

    assert Map.keys(writes) == [{0, 64, 0}]
  end

  test "ice melts above a liquid or melting block, not with Silk Touch nor where water evaporates" do
    water = Blocks.default_state("water")
    stone = %{below: Blocks.default_state("stone")}
    air = %{below: Blocks.default_state("air")}
    assert %{writes: %{{0, 64, 0} => {_, ^water}}, drops: []} = plan("ice", %{}, nil, true, stone)
    assert %{writes: %{{0, 64, 0} => {_, 0}}} = plan("ice", %{}, nil, true, air)

    assert %{writes: %{{0, 64, 0} => {_, 0}}} =
             plan("ice", %{}, nil, true, Map.put(stone, :evaporates, true))

    silk = enchanted("iron_pickaxe", %{"minecraft:silk_touch" => 1})
    assert %{writes: %{{0, 64, 0} => {_, 0}}, drops: [_ice]} = plan("ice", %{}, silk, true, stone)
  end

  test "a turtle egg cluster loses one egg; tools crack a decorated pot into its sherds" do
    three = Blocks.state("turtle_egg", %{"eggs" => "3"})
    two = Blocks.state("turtle_egg", %{"eggs" => "2"})
    assert %{writes: %{{0, 64, 0} => {^three, ^two}}} = plan("turtle_egg", %{"eggs" => "3"})

    assert items(plan("decorated_pot", %{}, ItemStack.new("iron_pickaxe")).drops) ==
             List.duplicate({"minecraft:brick", 1}, 4)

    assert items(plan("decorated_pot").drops) == [{"minecraft:decorated_pot", 1}]
    silk = enchanted("iron_pickaxe", %{"minecraft:silk_touch" => 1})
    assert items(plan("decorated_pot", %{}, silk).drops) == [{"minecraft:decorated_pot", 1}]
  end

  test "early stop finishes by elapsed owner ticks and abort consumes its callback identity" do
    stone = Data.block("stone")
    {:ok, rate} = Mining.rate(stone, 1, true)
    {:ok, attempt, [{:crack, 0}]} = MiningAttempt.start({0, 64, 0}, stone, rate, 123)
    token = attempt.token
    {:ok, finishing, []} = MiningAttempt.stop(attempt, stone, rate, 128)
    assert finishing.phase == :finishing
    assert current?(finishing, token)
    {:ok, waiting, _} = MiningAttempt.tick(finishing, stone, rate, 166)
    assert waiting.phase == :finishing
    {:ok, ready, [{:crack, -1}, :ready]} = MiningAttempt.tick(waiting, stone, rate, 167)
    assert ready.phase == :ready
    assert {:ok, ^ready, []} = MiningAttempt.tick(ready, stone, rate, 168)
    {:ok, cancelled, [{:crack, -1}]} = MiningAttempt.cancel(finishing)
    refute current?(cancelled, token)
    assert {:ok, ^cancelled, []} = MiningAttempt.tick(cancelled, stone, rate, 1000)
    assert {:ok, ^cancelled, []} = MiningAttempt.cancel(cancelled)
  end

  test "active progress cannot finish itself; changed state and stale work never complete a replacement" do
    stone = Data.block("stone")
    {:ok, rate} = Mining.rate(stone, 1, true)
    {:ok, attempt, _} = MiningAttempt.start({0, 64, 0}, stone, rate, 0)
    {:ok, attempt, [{:crack, -1}]} = MiningAttempt.tick(attempt, stone, rate, 100)
    assert attempt.phase == :active
    assert {:ok, ^attempt, []} = MiningAttempt.tick(attempt, stone, :infinity, 99)
    {:ok, ready, [{:crack, -1}, :ready]} = MiningAttempt.stop(attempt, stone, rate, 100)
    assert ready.phase == :ready
    {:ok, replacement, _} = MiningAttempt.start(attempt.position, stone, rate, 101)
    refute current?(replacement, attempt.token)

    {:ok, cancelled, [{:crack, -1}]} =
      MiningAttempt.tick(replacement, Data.block("dirt"), rate, 102)

    assert cancelled.phase == :cancelled
  end
end
