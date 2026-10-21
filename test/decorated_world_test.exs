defmodule Valimc.DecoratedWorldTest do
  @moduledoc """
  Decorated vanilla worlds (VMC-025d3): a region serves the full chunks its
  proto owner finalized, with their block entities, block ticks and pending
  post-processing, persists them once, and keeps them across restarts. The
  proto owners' own transactions and durable ring are `WorldgenProtoOwnerTest`'s.
  """
  # Serial: finalize transactions saturate the worldgen workers and dirty schedulers.
  use ExUnit.Case, async: false
  @moduletag :slow
  alias Valimc.{Native, TestScope, World}
  alias Valimc.World.{BlockSnapshot, Directory, Generator, ScheduledTicks, Spawn, Store}
  alias Valimc.Worldgen.{FullChunk, Proto}

  @seed 20_261_020
  @source "minecraft:overworld"
  # A region with a monster room and sulfur springs (DecorationOracle live).
  @key {25_000, -18_000}
  @moduletag timeout: 300_000

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-decorated-#{nonce}")
    File.mkdir_p!(base)

    File.write!(
      Spawn.path(base),
      JSON.encode!(%{
        "spawn" => [0, 100, 0],
        "yaw" => 0.0,
        "generator" => %{"type" => "vanilla", "seed" => @seed, "features" => true}
      })
    )

    keys = TestScope.neighborhood(@key, 3)
    TestScope.isolate(keys, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      stop(keys)
      File.rm_rf(base)
    end)

    {:ok, worldgen} = Generator.worldgen(@seed)
    %{base: base, keys: keys, worldgen: worldgen}
  end

  defp stop(keys) do
    for key <- keys,
        reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry, Valimc.ProtoRegistry],
        {pid, _} <- Registry.lookup(reg, key),
        do: TestScope.kill(pid)
  end

  # The region's full chunks when it is the first finalized.
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

  defp compute_expected(worldgen, key) do
    images = terrain(worldgen, Proto.around(key, 2))

    {:ok, {touched, 0}} =
      Native.worldgen_proto_decorate(
        worldgen,
        @source,
        Map.values(images),
        Proto.around(key, 1),
        true
      )

    images = Map.merge(images, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))
    own = Enum.map(Proto.chunks_of(key), &images[&1])
    {:ok, full} = Native.worldgen_proto_full(worldgen, own, Generator.protocol_biomes())
    full
  end

  # Under load a region's start can take longer than a call's default timeout.
  defp owner!(key, attempts \\ 600) do
    case World.owner(key) do
      {:ok, owner} ->
        {:ok, owner}

      {:error, _} when attempts > 0 ->
        Process.sleep(100)
        owner!(key, attempts - 1)
    end
  end

  # The region finalized whole by its proto owner (the order the expectations
  # follow), then all its chunks wanted, generated and stored by the live
  # region, which asks for them a few at a time (VMC-075).
  defp generate_all(key) do
    {:ok, _} = Proto.full_chunks(key)
    {:ok, {pid, _}} = owner!(key)
    {cx, cz} = hd(Proto.chunks_of(key))
    send(pid, {:want, self(), {cx, cz}, Proto.chunks_of(key)})
    {_, _, %{items: table}} = Directory.lookup(key)

    Valimc.TestWait.until(
      fn -> not Enum.any?(Proto.chunks_of(key), &BlockSnapshot.absent?(table, &1)) end,
      240_000
    )
  end

  # Terrain of `chunks` in parallel batches, with structures as a new world
  # generates them (VMC-025f5).
  defp terrain(worldgen, chunks) do
    chunks
    |> Enum.chunk_every(8)
    |> Task.async_stream(&Native.worldgen_proto_terrain(worldgen, @source, &1, true),
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, {:ok, list}} -> list end)
    |> Map.new(fn {x, z, image} -> {{x, z}, image} end)
  end

  defp restart(key) do
    {:ok, {pid, _}} = owner!(key)
    [{store, _}] = Registry.lookup(Valimc.RegionStoreRegistry, key)
    watch = Process.monitor(store)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert_receive {:DOWN, ^watch, :process, _, :normal}, 30_000
    {:ok, _} = owner!(key)
  end

  test "a region stores its full chunks with block entities, ticks and post-processing and serves them after a restart",
       ctx do
    full = expected(ctx.worldgen, @key)
    {:ok, parts} = FullChunk.parts(full, %{}, [])
    assert map_size(parts.block_entities) > 0
    generate_all(@key)

    assert Store.durable(ctx.base, @key, :columns) == parts.columns
    assert Store.durable(ctx.base, @key, :block_entities) == parts.block_entities
    assert Store.durable(ctx.base, @key, :post_processing) == parts.post_processing
    Valimc.TestWait.until(fn -> Proto.full_chunks(@key) == {:error, :handed_over} end)

    # Block ticks wait in the region's queue, due at its first tick.
    {:ok, {pid, _}} = owner!(@key)
    ticks = :sys.get_state(pid).resource.scheduled_ticks
    assert ScheduledTicks.size(ticks) == length(parts.ticks)

    for {position, state, 0, 0} <- Enum.take(parts.ticks, 50),
        do: assert(ScheduledTicks.scheduled?(ticks, position, state))

    # The region serves the blocks of the full chunks.
    {:ok, blocks} = World.Blocks.new(@key, %{}, parts.columns)
    {cx, cz} = hd(Proto.chunks_of(@key))

    for x <- [0, 5, 15], z <- [0, 9, 15], y <- -64..319//7 do
      position = {cx * 16 + x, y, cz * 16 + z}
      assert World.get_block(position) == World.Blocks.get(blocks, position)
    end

    # A restart serves the same chunks, edits included, without generating them again.
    {cx, cz} = List.last(Proto.chunks_of(@key))
    position = {cx * 16 + 3, 70, cz * 16 + 3}
    glass = Valimc.Registry.Blocks.default_state("glass")
    :ok = World.set_block(position, glass)
    restart(@key)
    assert World.get_block(position) == glass
    assert Store.durable(ctx.base, @key, :columns) == parts.columns
    assert Store.durable(ctx.base, @key, :block_entities) == parts.block_entities
  end
end
