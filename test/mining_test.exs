defmodule Valimc.MiningTest do
  # Hardness, tool speeds, submersion, loot and attempt timing are compared by the
  # mining, mining_tool, player_mining, mining_loot, random_mining_loot and
  # mining_attempt oracle stages; these tests cover ValiMC's own boundaries.
  use ExUnit.Case, async: true
  alias Valimc.PlayerMiningAttempt
  alias Valimc.Physics.{Mining, MiningLoot, RandomMiningLoot}
  alias Valimc.Protocol.{Data, ItemStack}

  test "progress thresholds hold and malformed inputs are explicit errors" do
    {:ok, rate} = Mining.rate(Data.block("stone"), 1, true)
    assert {:ok, %{complete: false, stoppable: true}} = Mining.advance(rate, 31)
    assert {:ok, %{complete: true}} = Mining.advance(rate, 44)

    for args <- [{1, -1, true}, {1, 1, nil}],
        do: assert(apply(Mining, :rate, Tuple.to_list(args)) == {:error, :invalid_mining_input})

    assert {:error, :invalid_mining_input} = Mining.advance(rate, -1)
  end

  test "unsupported random/context families never become guessed drops" do
    ore = Data.item_block(Data.item("diamond_ore"))
    assert {:error, :unsupported_mining_loot} = MiningLoot.drops(ore, nil, true)
    assert {:ok, []} = MiningLoot.drops(ore, nil, false)

    assert {:ok, [ItemStack.new("oak_planks")]} ==
             MiningLoot.drops(Data.block("oak_planks"), nil, true)

    for state <- [-1, Data.block_state_count(), nil],
        do: assert({:error, :invalid_mining_loot} == MiningLoot.drops(state, nil, true))

    for state <- [nil, -1, Data.block_state_count(), ore, Data.block("bedrock")] do
      refute RandomMiningLoot.supported?(state)
      assert RandomMiningLoot.drops(state, nil, true) == {:error, :unsupported_mining_loot}
    end
  end

  test "early stop finishes by elapsed owner ticks and abort consumes its callback identity" do
    stone = Data.block("stone")
    {:ok, rate} = Mining.rate(stone, 1, true)
    {:ok, attempt, [{:crack, 0}]} = PlayerMiningAttempt.start({0, 64, 0}, stone, rate, 123)
    token = attempt.token
    {:ok, finishing, []} = PlayerMiningAttempt.stop(attempt, stone, rate, 128)
    assert finishing.phase == :finishing
    assert PlayerMiningAttempt.current?(finishing, token)
    {:ok, waiting, _} = PlayerMiningAttempt.tick(finishing, stone, rate, 166)
    assert waiting.phase == :finishing
    {:ok, ready, [{:crack, -1}, :ready]} = PlayerMiningAttempt.tick(waiting, stone, rate, 167)
    assert ready.phase == :ready
    assert {:ok, ^ready, []} = PlayerMiningAttempt.tick(ready, stone, rate, 168)
    {:ok, cancelled, [{:crack, -1}]} = PlayerMiningAttempt.cancel(finishing)
    refute PlayerMiningAttempt.current?(cancelled, token)
    assert {:ok, ^cancelled, []} = PlayerMiningAttempt.tick(cancelled, stone, rate, 1000)
    assert {:ok, ^cancelled, []} = PlayerMiningAttempt.cancel(cancelled)
  end

  test "active progress cannot finish itself; changed state and stale work never complete a replacement" do
    stone = Data.block("stone")
    {:ok, rate} = Mining.rate(stone, 1, true)
    {:ok, attempt, _} = PlayerMiningAttempt.start({0, 64, 0}, stone, rate, 0)
    {:ok, attempt, [{:crack, -1}]} = PlayerMiningAttempt.tick(attempt, stone, rate, 100)
    assert attempt.phase == :active
    assert {:ok, ^attempt, []} = PlayerMiningAttempt.tick(attempt, stone, :infinity, 99)
    {:ok, ready, [{:crack, -1}, :ready]} = PlayerMiningAttempt.stop(attempt, stone, rate, 100)
    assert ready.phase == :ready
    {:ok, replacement, _} = PlayerMiningAttempt.start(attempt.position, stone, rate, 101)
    refute PlayerMiningAttempt.current?(replacement, attempt.token)

    {:ok, cancelled, [{:crack, -1}]} =
      PlayerMiningAttempt.tick(replacement, Data.block("dirt"), rate, 102)

    assert cancelled.phase == :cancelled
  end
end
