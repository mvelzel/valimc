defmodule Valimc.GeneratedWorldTest do
  @moduledoc "Vanilla worlds generate their chunks' terrain once and keep it (VMC-024d, VMC-075; terrain-only worlds)."
  use ExUnit.Case, async: true
  import Bitwise
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.{Generator, Spawn, Store}

  @seed 20_261_020

  setup do
    nonce = System.unique_integer([:positive])
    key = {70_000 + rem(nonce, 3_333) * 3, -1300}
    base = Path.join(System.tmp_dir!(), "valimc-generated-#{nonce}")
    # Terrain only, as worlds generated before VMC-025d.
    :ok = Generator.create(base, @seed, features: false)
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      stop(key)
      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.config(:region_size)
    %{key: key, base: base, chunk: {rx * size + 3, rz * size + 5}, size: size}
  end

  defp stop(key) do
    for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
        {pid, _} <- Registry.lookup(reg, key),
        do: TestScope.kill(pid)
  end

  # The generated chunk's states (Y fastest from -64, then X, then Z).
  defp generated(chunk) do
    {:ok, state} = Valimc.Worldgen.new(@seed)

    {:ok, [{blocks, _updates}]} =
      Valimc.Native.worldgen_build_terrain(state, "minecraft:overworld", true, [chunk])

    for <<id::16 <- blocks>>, do: id
  end

  defp at(states, {x, y, z}), do: Enum.at(states, y + 64 + ((x &&& 15) + (z &&& 15) * 16) * 384)

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

  defp restart(key) do
    {:ok, {pid, _}} = owner!(key)
    [{store, _}] = Registry.lookup(Valimc.RegionStoreRegistry, key)
    watch = Process.monitor(store)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert_receive {:DOWN, ^watch, :process, _, :normal}
    {:ok, _} = owner!(key)
  end

  test "clients learn vanilla's hashed seed and that the world is not flat" do
    assert Generator.client_info(:flat) == {0, true}
    # BiomeManager.obfuscateSeed(20261020) on the pinned server.
    assert Generator.client_info({:vanilla, @seed}) == {185_046_262_534_519_193, false}
  end

  test "world.json records the generator and a spawn on the generated surface", ctx do
    assert Generator.of(ctx.base) == {:vanilla, @seed}
    assert Generator.of(System.tmp_dir!()) == :flat
    {:ok, meta} = ctx.base |> Spawn.path() |> File.read!() |> JSON.decode()
    [0, y, 0] = meta["spawn"]
    states = generated({0, 0})
    air = Valimc.Registry.Blocks.default_state("air")
    assert at(states, {0, y - 1, 0}) != air
    assert Enum.all?((y + 0)..319, &(at(states, {0, &1, 0}) == air))
  end

  test "a region loads generated terrain, persists it, and keeps edits over it", ctx do
    {:ok, _owner} = owner!(ctx.key)
    {cx, cz} = ctx.chunk
    states = generated(ctx.chunk)

    positions =
      for x <- [0, 7, 15],
          z <- [0, 9, 15],
          y <- [-64, -40, 0, 30, 60, 62, 63, 64, 70, 90, 130],
          do: {cx * 16 + x, y, cz * 16 + z}

    for position <- positions,
        do: assert(World.get_block(position) == at(states, position), inspect(position))

    assert Enum.any?(positions, &(at(states, &1) != World.Chunk.base(elem(&1, 1)))),
           "the sampled terrain differs from flat terrain"

    # Only the chunk read was generated (VMC-075), as the generator makes it.
    columns = Store.durable(ctx.base, ctx.key, :columns)
    assert Map.keys(columns) == [ctx.chunk]
    assert columns[ctx.chunk] == Generator.columns({:vanilla, @seed}, [ctx.chunk])[ctx.chunk]

    edited = {cx * 16 + 4, 20, cz * 16 + 4}
    glass = Valimc.Registry.Blocks.default_state("glass")
    :ok = World.set_block(edited, glass)
    restart(ctx.key)
    assert World.get_block(edited) == glass
    untouched = {cx * 16 + 9, 40, cz * 16 + 2}
    assert World.get_block(untouched) == at(states, untouched)
    assert Map.keys(Store.durable(ctx.base, ctx.key, :columns)) == [ctx.chunk]
  end
end
