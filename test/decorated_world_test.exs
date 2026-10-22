defmodule Valimc.DecoratedWorldTest do
  @moduledoc """
  Decorated vanilla worlds (VMC-025d3, VMC-077n): a region serves the full
  chunks its dimension's generation scheduler made, with their block entities,
  block ticks and pending post-processing, persists them once, and keeps them
  across restarts. The scheduler's own order and snapshot are
  `WorldgenSchedulerTest`'s.
  """
  # Serial: generation saturates the pool and the dirty schedulers.
  use ExUnit.Case, async: false
  @moduletag :slow
  alias Valimc.{Native, TestScope, World}
  alias Valimc.World.{BlockSnapshot, Region, RegionGeneration}
  alias Valimc.Worldgen.Generator
  alias Valimc.World.{RegionStorage, ScheduledTicks}
  alias Valimc.Worldgen.{FullChunk, Scheduler}

  @seed 20_261_020
  @source "minecraft:overworld"
  # A region with a monster room and sulfur springs (DecorationOracle live).
  @key {25_000, -18_000}
  @moduletag timeout: 300_000

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-decorated-#{nonce}")
    File.mkdir_p!(base)

    :ok =
      Valimc.World.Spec.write(base, %{"type" => "vanilla", "seed" => @seed, "features" => true})

    keys = TestScope.neighborhood(@key, 3)
    TestScope.isolate(keys, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      stop(keys)

      for {pid, _} <- Registry.lookup(Valimc.Worldgen.Schedulers, {base, :overworld}),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, worldgen} = Generator.worldgen(@seed)
    %{base: base, keys: keys, worldgen: worldgen}
  end

  defp stop(keys) do
    for key <- keys,
        {pid, _} <- Valimc.TestWorld.registered(key),
        do: TestScope.kill(pid)
  end

  # The region's full chunks when one request wants all of them: its 10 × 10
  # decorated Z outer, X inner over terrain.
  defp expected(worldgen, key) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        full = compute_expected(worldgen, key)
        :persistent_term.put({__MODULE__, key}, full)
        full

      full ->
        full
    end
  end

  defp compute_expected(worldgen, {rx, rz} = key) do
    order = key |> RegionGeneration.chunks_of() |> Enum.flat_map(&around/1) |> Enum.uniq()
    order = Enum.sort_by(order, fn {x, z} -> {z, x} end)
    origin = {rx * 8 - 2, rz * 8 - 2}
    {:ok, cells} = Native.gen_reference(worldgen, @source, origin, 12, order, true)

    for {x, z} <- RegionGeneration.chunks_of(key) do
      cell = Enum.at(cells, (z - rz * 8 + 2) * 12 + (x - rx * 8 + 2))
      {:ok, full} = Native.gen_full(worldgen, cell, Generator.protocol_biomes())
      # Lit alone, as the scheduler sends it (VMC-077c).
      %{full | image: Map.fetch!(World.Blocks.lit_images(%{{x, z} => full.image}, true), {x, z})}
    end
  end

  defp around({x, z}), do: for(dz <- -1..1, dx <- -1..1, do: {x + dx, z + dz})

  # Under load a region's start can take longer than a call's default timeout.
  defp owner!(key, attempts \\ 600) do
    case Valimc.TestWorld.owner(key) do
      {:ok, owner} ->
        {:ok, owner}

      {:error, _} when attempts > 0 ->
        Process.sleep(100)
        owner!(key, attempts - 1)
    end
  end

  # All the region's chunks wanted at once, generated and stored by the live
  # region (VMC-075).
  defp generate_all(key) do
    {:ok, {pid, _}} = owner!(key)
    Valimc.World.Region.ticket(pid, key, :forced, RegionGeneration.chunks_of(key))
    {_, _, %{publication: table}} = Valimc.TestWorld.lookup(key)

    Valimc.TestWait.until(
      fn -> not Enum.any?(RegionGeneration.chunks_of(key), &BlockSnapshot.absent?(table, &1)) end,
      240_000
    )
  end

  defp restart(key) do
    {:ok, {pid, _}} = owner!(key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, _} = owner!(key)
  end

  # What the running owner has made durable.
  defp durable(ctx, key) do
    {:ok, {pid, _}} = owner!(key)
    :ok = Region.flush(pid)
    {:ok, parts} = RegionStorage.read(ctx.base, :overworld, key)
    parts
  end

  test "a region stores its full chunks with block entities, ticks and post-processing and serves them after a restart",
       ctx do
    full = expected(ctx.worldgen, @key)
    {:ok, parts} = FullChunk.parts(full, %{}, [])
    assert map_size(parts.block_entities) > 0
    generate_all(@key)

    stored = durable(ctx, @key)
    assert stored.columns == parts.columns
    assert stored.block_entities == parts.block_entities
    assert stored.post_processing == parts.post_processing
    # One record per chunk holds its ticks (VMC-077w).
    assert Enum.sort(for {p, b, _, _} <- stored.ticks, do: {p, b}) ==
             Enum.sort(for {p, b, _, _} <- parts.ticks, do: {p, b})

    # The scheduler dropped the proto chunks the region made durable.
    Valimc.TestWait.until(fn ->
      {:ok, cells} = Scheduler.cells(ctx.base, :overworld, RegionGeneration.chunks_of(@key))
      Enum.all?(cells, &is_nil/1)
    end)

    # Block ticks wait in the region's queue, due at its first tick.
    {:ok, owner} = owner!(@key)
    ticks = Valimc.TestRegion.section(owner).scheduled_ticks
    assert ScheduledTicks.size(ticks) == length(parts.ticks)

    for {position, state, 0, 0} <- Enum.take(parts.ticks, 50),
        do: assert(Map.has_key?(ticks.index, {position, state}))

    # The region serves the blocks of the full chunks.
    {:ok, blocks} = World.Blocks.new(@key, %{}, parts.columns)
    {cx, cz} = hd(RegionGeneration.chunks_of(@key))

    for x <- [0, 5, 15], z <- [0, 9, 15], y <- -64..319//7 do
      position = {cx * 16 + x, y, cz * 16 + z}
      assert Valimc.TestBlocks.get(position) == World.Blocks.get(blocks, position)
    end

    # A restart serves the same chunks, edits included, without generating them again.
    {cx, cz} = List.last(RegionGeneration.chunks_of(@key))
    position = {cx * 16 + 3, 70, cz * 16 + 3}
    glass = Valimc.Data.Blocks.default_state("glass")
    :ok = Valimc.TestBlocks.set(position, glass)
    restart(@key)
    assert Valimc.TestBlocks.get(position) == glass
    # The edit is folded into its chunk's image; the other chunks are as generated.
    stored = durable(ctx, @key)
    assert Map.delete(stored.columns, {cx, cz}) == Map.delete(parts.columns, {cx, cz})
    assert stored.block_entities == parts.block_entities
  end
end
