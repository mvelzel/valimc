defmodule Valimc.PlayerMiningAttemptTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerMiningAttempt, Protocol.Data}
  alias Valimc.Physics.Mining
  alias Valimc.Protocol.Packets

  test "only visible crack stages and the explicit clear stage enter the outgoing codec" do
    for {id, stage} <- [{-1, 0}, {2_147_483_648, 0}, {1, -2}, {1, 10}],
        do:
          assert_raise(FunctionClauseError, fn ->
            Packets.block_destruction(id, {0, 64, 0}, stage)
          end)
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

  test "current tool rate is applied to the whole elapsed prefix and cracks are coalesced" do
    stone = Data.block("stone")
    {:ok, slow} = Mining.rate(stone, 1, true)
    {:ok, fast} = Mining.rate(stone, 8, true)
    {:ok, attempt, _} = PlayerMiningAttempt.start({0, 64, 0}, stone, slow, 0)
    {:ok, attempt, []} = PlayerMiningAttempt.tick(attempt, stone, slow, 1)
    {:ok, attempt, [{:crack, 5}]} = PlayerMiningAttempt.tick(attempt, stone, fast, 2)
    {:ok, ready, [{:crack, -1}, :ready]} = PlayerMiningAttempt.stop(attempt, stone, fast, 3)
    assert ready.phase == :ready
    {:ok, instant, [:ready]} = PlayerMiningAttempt.start({0, 64, 0}, stone, :infinity, 0)
    assert instant.phase == :ready
  end
end
