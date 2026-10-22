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
    {:ok, t} = ScheduledTicks.schedule(t, {3, 0, 0}, 1, 3, -1)
    {:ok, ^t} = ScheduledTicks.schedule(t, {0, 0, 0}, 1, 1, 0)
    assert {[], ^t} = ScheduledTicks.take_due(t, 2)
    assert {[{{2, 0, 0}, 1}, {{3, 0, 0}, 1}, {{1, 0, 0}, 1}], t} = ScheduledTicks.take_due(t, 4)
    assert ScheduledTicks.size(t) == 1
    assert ScheduledTicks.dump(t, 4) == [{{0, 0, 0}, 1, 1, 0}]

    assert ScheduledTicks.load(ScheduledTicks.dump(t, 4), 100)
           |> ScheduledTicks.take_due(101)
           |> elem(0) ==
             [{{0, 0, 0}, 1}]
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
