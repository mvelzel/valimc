defmodule Valimc.TickPipelineTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.Data
  alias Valimc.TestScope
  alias Valimc.World.{Region, ScheduledTicks}

  defmodule Spread do
    @moduledoc false
    def states, do: [Data.block("grass_block"), Data.block("dirt")]

    # A sampled grass block turns to dirt and schedules itself to become stone.
    def random_tick(position, 9, _read, _random),
      do: [{:set, position, Data.block("dirt")}, {:schedule, position, Data.block("dirt"), 2, 0}]

    def random_tick(_, _, _, _), do: []
    def scheduled_tick(position, 10, _read, _random), do: [{:set, position, Data.block("stone")}]
  end

  setup do
    nonce = System.unique_integer([:positive])
    key = {70_000 + rem(nonce, 3_333) * 3, 1800}
    base = Path.join(System.tmp_dir!(), "valimc-ticks-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual, tick_behaviours: [Spread])

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key}
  end

  test "scheduled ticks run in trigger, priority and insertion order, once per position and block" do
    {:ok, t} = ScheduledTicks.schedule(ScheduledTicks.new(), {0, 0, 0}, 1, 5, 0)
    {:ok, t} = ScheduledTicks.schedule(t, {1, 0, 0}, 1, 3, 1)
    {:ok, t} = ScheduledTicks.schedule(t, {2, 0, 0}, 1, 3, -1)
    # Another chunk's tick joins the order when its chunk ticks.
    {:ok, t} = ScheduledTicks.schedule(t, {19, 0, 0}, 1, 3, -1)
    {:ok, ^t} = ScheduledTicks.schedule(t, {0, 0, 0}, 1, 1, 0)
    chunks = [{0, 0}, {1, 0}]
    assert {[], t} = ScheduledTicks.take_due(t, 2, chunks)

    assert {[{{2, 0, 0}, 1}, {{19, 0, 0}, 1}, {{1, 0, 0}, 1}], t} =
             ScheduledTicks.take_due(t, 4, chunks)

    assert ScheduledTicks.size(t) == 1
    records = %{{:ticks, {0, 0}} => ScheduledTicks.record(t.containers[{0, 0}])}
    assert records[{:ticks, {0, 0}}] == [{5, 0, {0, 0, 0}, 1}]

    # Stored dues are relative to the shift, which a rebase moves.
    loaded = ScheduledTicks.from_records(Map.put(records, {:ticks, :shift}, 96))
    assert {[], _} = ScheduledTicks.take_due(loaded, 100, chunks)
    assert {[{{0, 0, 0}, 1}], _} = ScheduledTicks.take_due(loaded, 101, chunks)
  end

  test "ticks of chunks that do not tick stay untouched until their chunk ticks; a rebase keeps delays" do
    t =
      Enum.reduce(0..999, ScheduledTicks.new(), fn n, acc ->
        {:ok, acc} = ScheduledTicks.schedule(acc, {32 + rem(n, 16), 64, div(n, 16)}, 7, 1, 0)
        acc
      end)

    {:ok, t} = ScheduledTicks.schedule(t, {0, 64, 0}, 7, 1, 0)
    {due, after_take} = ScheduledTicks.take_due(t, 5, [{0, 0}])
    assert due == [{{0, 64, 0}, 7}]
    # Only the taken tick changed: the far chunk's thousand are the same term.
    assert after_take.containers[{2, 0}] === t.containers[{2, 0}]

    refute Map.has_key?(after_take.containers, {0, 0})

    rebased = ScheduledTicks.rebase(after_take, 5, 1005)
    assert rebased.containers === after_take.containers
    assert {[], _} = ScheduledTicks.take_due(rebased, 1000, [{2, 0}])
    assert {taken, _} = ScheduledTicks.take_due(rebased, 1001, [{2, 0}])
    assert length(taken) == 256
  end

  defp blocks(owner, key, block) do
    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16

    positions =
      for x <- 0..(span - 1), z <- 0..(span - 1), do: {rx * span + x, 63, rz * span + z}

    for batch <- Enum.chunk_every(positions, 128),
        {:ok, observed} = Region.observe_blocks(owner, batch),
        {position, ^block} <- observed.blocks,
        do: position
  end

  test "a manual owner ticks only when stepped; random and scheduled effects apply and persist",
       ctx do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    TestScope.simulate(owner, ctx.key)
    surface = blocks(owner, ctx.key, Data.block("grass_block"))
    assert length(surface) > 1000
    assert blocks(owner, ctx.key, Data.block("dirt")) |> Enum.filter(&(&1 in surface)) == []

    assert {:ok, 1} = Region.step(owner)
    converted = Enum.filter(blocks(owner, ctx.key, Data.block("dirt")), &(&1 in surface))
    assert converted != []

    # Restart before the scheduled ticks fire: they are saved with the region.
    {pid, _} = owner
    # The final save on unload holds the scheduled ticks.
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    TestScope.simulate(owner, ctx.key)
    # The game tick continues from the saved one (VMC-077f).
    assert {:ok, 3} = Region.step(owner, 2)
    stone = blocks(owner, ctx.key, Data.block("stone"))
    assert Enum.all?(converted, &(&1 in stone))
  end
end
