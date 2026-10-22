defmodule Valimc.RegionLifecycleTest do
  use ExUnit.Case, async: false
  # Serial: lowers the global region cap and counts every owner.
  alias Valimc.TestScope
  alias Valimc.World.Region

  @coral Valimc.Data.Blocks.default_state("tube_coral_block")
  @dead Valimc.Data.Blocks.default_state("dead_tube_coral_block")

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-lifecycle-#{nonce}")
    row = 3000 + rem(nonce, 5000)
    keys = for x <- 0..11, do: {6000 + x, row}
    TestScope.isolate(keys, world_path: base, region_unload_delay_ms: 50)

    on_exit(fn ->
      for key <- keys,
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{keys: keys, base: base}
  end

  defp chunks({rx, rz}) do
    size = Valimc.Data.Grid.region_size()
    for x <- 0..(size - 1), z <- 0..(size - 1), do: {rx * size + x, rz * size + z}
  end

  defp gone?(key), do: Valimc.TestWorld.registered(key) == []

  test "a long walk never reaches max_regions; regions left behind save and unload", ctx do
    limit = Valimc.config(:max_regions)
    # Two regions held at a time, one more while the last one left is retiring.
    Application.put_env(:valimc, :max_regions, :ets.info(Valimc.RegionRoutes, :size) + 3)

    try do
      [first | _] = ctx.keys
      {rx, rz} = first

      edit =
        {rx * Valimc.Data.Grid.region_size() * 16 + 3, 70,
         rz * Valimc.Data.Grid.region_size() * 16}

      table = fn key -> elem(Valimc.TestWorld.lookup(key), 2).publication end

      tables =
        ctx.keys
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce([], fn [here, ahead], tables ->
          tables =
            for key <- [here, ahead], reduce: tables do
              acc ->
                assert {:ok, pid} = Valimc.TestWorld.region(key)
                Region.ticket(pid, key, :player_loading, hd(chunks(key)), chunks(key))
                if key == first, do: assert(:ok = Valimc.TestBlocks.set(edit, @coral))
                {:ok, _} = Valimc.TestWorld.owner(key)
                [table.(key) | acc]
            end

          # The region behind withdraws, saves and stops.
          behind = {elem(here, 0) - 1, elem(here, 1)}

          if behind in ctx.keys do
            {pid, _, _} = Valimc.TestWorld.lookup(behind) || {nil, nil, nil}
            if pid, do: Region.ticket(pid, behind, :player_loading, nil, [])
            Valimc.TestWait.until(fn -> gone?(behind) end)
          end

          tables
        end)

      for key <- Enum.drop(ctx.keys, -2), do: assert(gone?(key))
      # Their published tables (and owners' memory) are freed.
      assert Enum.count(tables, &(:ets.info(&1) == :undefined)) >= length(ctx.keys) - 2

      # What was edited before the unload is there when the region loads again.
      Application.put_env(:valimc, :max_regions, limit)
      assert Valimc.TestBlocks.get(edit) == @coral
    after
      Application.put_env(:valimc, :max_regions, limit)
    end
  end

  test "only chunks a simulation ticket covers tick; their due ticks run once it arrives", ctx do
    key = Enum.at(ctx.keys, 5)
    TestScope.isolate(key, region_ticks: :manual, random_tick_speed: 0)
    {:ok, owner} = Valimc.TestWorld.owner(key)
    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    ticking = {rx * span + 8, 64, rz * span + 8}
    idle = {rx * span + 8 + 64, 64, rz * span + 8 + 64}
    {:ok, observed} = Region.observe_blocks(owner, [ticking, idle])
    # Coral away from water schedules the tick that kills it (60–99 ticks).
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{ticking => @coral, idle => @coral})

    Region.ticket(owner, key, :player_simulation, nil, [
      Valimc.Data.Grid.chunk_key(8 + rx * span, 8 + rz * span)
    ])

    {:ok, _} = Region.step(owner, 100)
    assert Valimc.TestBlocks.get(ticking) == @dead
    assert Valimc.TestBlocks.get(idle) == @coral

    Region.ticket(owner, key, :forced, nil, [
      Valimc.Data.Grid.chunk_key(elem(idle, 0), elem(idle, 2))
    ])

    {:ok, _} = Region.step(owner, 1)
    assert Valimc.TestBlocks.get(idle) == @dead
  end
end
