defmodule Valimc.DecoratedWorldTest do
  @moduledoc """
  Decorated vanilla worlds (VMC-025d3): a region serves the full chunks its
  proto owner finalized, with their block entities, block ticks and pending
  post-processing, persists them once, and keeps them across restarts.
  """
  use ExUnit.Case, async: true
  alias Valimc.{Native, TestScope, World}
  alias Valimc.World.{Generator, ScheduledTicks, Spawn, Store}
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
    {:ok, terrain} = Native.worldgen_proto_terrain(worldgen, @source, Proto.around(key, 2))
    images = Map.new(terrain, fn {x, z, image} -> {{x, z}, image} end)

    {:ok, {touched, 0}} =
      Native.worldgen_proto_decorate(worldgen, Map.values(images), Proto.around(key, 1))

    images = Map.merge(images, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))
    own = Enum.map(Proto.chunks_of(key), &images[&1])
    {:ok, full} = Native.worldgen_proto_full(worldgen, own, Generator.protocol_biomes())
    full
  end

  # A region's load waits for its proto owner's transaction.
  defp owner!(key, attempts \\ 600) do
    case World.owner(key) do
      {:ok, owner} ->
        {:ok, owner}

      {:error, _} when attempts > 0 ->
        Process.sleep(100)
        owner!(key, attempts - 1)
    end
  end

  defp restart(key) do
    {:ok, {pid, _}} = owner!(key)
    [{store, _}] = Registry.lookup(Valimc.RegionStoreRegistry, key)
    watch = Process.monitor(store)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert_receive {:DOWN, ^watch, :process, _, :normal}, 30_000
    {:ok, _} = owner!(key)
  end

  test "new worlds are decorated and spawn on the decorated surface" do
    base =
      Path.join(System.tmp_dir!(), "valimc-decorated-new-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(base) end)
    :ok = Generator.create(base, @seed)
    assert Generator.decorated?(base)
    assert Generator.of(base) == {:vanilla, @seed}
    {:ok, meta} = base |> Spawn.path() |> File.read!() |> JSON.decode()
    # Vanilla's spawn search (VMC-027d) over the full chunks of the origin's
    # region as its first transaction decorates them.
    origin = Valimc.World.SpawnSearch.origin(@seed)
    {:ok, worldgen} = Generator.worldgen(@seed)
    full = expected(worldgen, Valimc.World.region_key(origin))
    chunk = Enum.find(full, &({&1.x, &1.z} == origin))
    {x, y, z} = Valimc.World.SpawnSearch.spawn_in_chunk(origin, chunk.image)
    assert meta["spawn"] == [x, y, z]

    terrain = Path.join(base, "terrain")
    :ok = Generator.create(terrain, @seed, features: false)
    refute Generator.decorated?(terrain)
  end

  test "a region stores its full chunks with block entities, ticks and post-processing", ctx do
    full = expected(ctx.worldgen, @key)
    {:ok, parts} = FullChunk.parts(full, %{}, [])
    assert map_size(parts.block_entities) > 0
    {:ok, _} = owner!(@key)

    assert Store.durable(ctx.base, @key, :columns) == parts.columns
    assert Store.durable(ctx.base, @key, :block_entities) == parts.block_entities
    assert Store.durable(ctx.base, @key, :post_processing) == parts.post_processing
    assert Proto.full_chunks(@key) == {:error, :handed_over}

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
  end

  test "a restart serves the same chunks without generating them again", ctx do
    full = expected(ctx.worldgen, @key)
    {:ok, parts} = FullChunk.parts(full, %{}, [])
    {:ok, _} = owner!(@key)
    {cx, cz} = List.last(Proto.chunks_of(@key))
    position = {cx * 16 + 3, 70, cz * 16 + 3}
    glass = Valimc.Registry.Blocks.default_state("glass")
    :ok = World.set_block(position, glass)
    restart(@key)
    assert World.get_block(position) == glass
    assert Store.durable(ctx.base, @key, :columns) == parts.columns
    assert Store.durable(ctx.base, @key, :block_entities) == parts.block_entities
  end

  test "a neighbouring region continues from the durable ring", ctx do
    {:ok, _} = owner!(@key)
    stop(ctx.keys)
    east = {elem(@key, 0) + 1, elem(@key, 1)}
    {:ok, _} = owner!(east)

    # As if the two regions were finalized one after the other in one area.
    area = Enum.uniq(Proto.around(@key, 2) ++ Proto.around(east, 2))
    {:ok, terrain} = Native.worldgen_proto_terrain(ctx.worldgen, @source, area)
    images = Map.new(terrain, fn {x, z, image} -> {{x, z}, image} end)

    images =
      Enum.reduce(
        [Proto.around(@key, 1), Proto.around(east, 1) -- Proto.around(@key, 1)],
        images,
        fn order, acc ->
          {:ok, {touched, 0}} =
            Native.worldgen_proto_decorate(ctx.worldgen, Map.values(acc), order)

          Map.merge(acc, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))
        end
      )

    {:ok, full} =
      Native.worldgen_proto_full(
        ctx.worldgen,
        Enum.map(Proto.chunks_of(east), &images[&1]),
        Generator.protocol_biomes()
      )

    {:ok, parts} = FullChunk.parts(full, %{}, [])
    assert Store.durable(ctx.base, east, :columns) == parts.columns
  end
end
