defmodule Valimc.WorldgenProtoOwnerTest do
  @moduledoc """
  Proto owners and the finalize transaction (VMC-025d2): regions become final
  across region borders exactly as one decoration of the same chunks in the
  same order, concurrent neighbours serialize, and decorations survive
  restarts and crashes at each step of the transaction.
  """
  use ExUnit.Case, async: true
  alias Valimc.{Native, TestScope}
  alias Valimc.World.{Generator, Spawn}
  alias Valimc.Worldgen.Proto

  @seed 20_261_020
  @source "minecraft:overworld"
  @moduletag timeout: 300_000

  setup do
    nonce = System.unique_integer([:positive])
    key = {40 * rem(nonce, 1000) - 20_000, -7_000 - 10 * div(rem(nonce, 100_000), 1000)}
    base = Path.join(System.tmp_dir!(), "valimc-proto-#{nonce}")
    File.mkdir_p!(base)

    File.write!(
      Spawn.path(base),
      JSON.encode!(%{
        "spawn" => [0, 100, 0],
        "yaw" => 0.0,
        "generator" => %{"type" => "vanilla", "seed" => @seed, "features" => true}
      })
    )

    keys = TestScope.neighborhood(key, 3)
    TestScope.isolate(keys, world_path: base)

    on_exit(fn ->
      stop(keys)
      File.rm_rf(base)
    end)

    {:ok, worldgen} = Generator.worldgen(@seed)
    %{key: key, keys: keys, base: base, worldgen: worldgen}
  end

  defp stop(keys) do
    for key <- keys, {pid, _} <- Registry.lookup(Valimc.ProtoRegistry, key), do: TestScope.kill(pid)
  end

  defp east({x, z}), do: {x + 1, z}

  # What finalizing `regions` one after the other gives: their 12 × 12 areas'
  # terrain, then each region's undecorated 10 × 10 decorated Z outer, X inner.
  defp sequential(worldgen, regions) do
    area = regions |> Enum.flat_map(&Proto.around(&1, 2)) |> Enum.uniq()
    {:ok, terrain} = Native.worldgen_proto_terrain(worldgen, @source, area)
    images = Map.new(terrain, fn {x, z, image} -> {{x, z}, image} end)

    {images, _} =
      Enum.reduce(regions, {images, MapSet.new()}, fn region, {images, decorated} ->
        order = Enum.reject(Proto.around(region, 1), &MapSet.member?(decorated, &1))
        {:ok, {touched, 0}} = Native.worldgen_proto_decorate(worldgen, Map.values(images), order)
        touched = Map.new(touched, fn {x, z, image} -> {{x, z}, image} end)
        {Map.merge(images, touched), MapSet.union(decorated, MapSet.new(order))}
      end)

    Map.new(regions, fn region ->
      own = Enum.map(Proto.chunks_of(region), &images[&1])
      {:ok, full} = Native.worldgen_proto_full(worldgen, own, Generator.protocol_biomes())
      {region, full}
    end)
  end

  defp full(key) do
    {:ok, full} = Proto.full_chunks(key)
    full
  end

  defp assert_same(ours, want) do
    assert length(ours) == 64

    for {a, b} <- Enum.zip(ours, want) do
      assert {a.x, a.z} == {b.x, b.z}
      assert a.image == b.image, "chunk #{a.x}, #{a.z} differs"
      assert a == b
    end
  end

  defp pid(key) do
    {:ok, pid} = Proto.owner(key)
    pid
  end

  defp await(fun, attempts \\ 2000) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never held")
      Process.sleep(5)
      await(fun, attempts - 1)
    end
  end

  test "a finalized region equals its 10 × 10 decorated in order over terrain", ctx do
    want = sequential(ctx.worldgen, [ctx.key])
    assert_same(full(ctx.key), want[ctx.key])
    # Asking again gives the same chunks.
    assert_same(full(ctx.key), want[ctx.key])
    # Every chunk of the 10 × 10 is decorated once; the ring stays proto.
    ring = Proto.around(ctx.key, 1) -- Proto.chunks_of(ctx.key)

    for chunk <- ring do
      state = :sys.get_state(pid(Valimc.World.region_key(chunk)))
      assert {:decorated, _} = state.chunks[chunk]
      assert map_size(state.grants) == 0
    end
  end

  test "neighbours finalized one after the other equal one decoration in that order", ctx do
    want = sequential(ctx.worldgen, [ctx.key, east(ctx.key)])
    assert_same(full(ctx.key), want[ctx.key])
    assert_same(full(east(ctx.key)), want[east(ctx.key)])
  end

  test "concurrent neighbours serialize: the result is one of the two orders", ctx do
    a = ctx.key
    b = east(a)
    tasks = [Task.async(fn -> full(a) end), Task.async(fn -> full(b) end)]
    [ours_a, ours_b] = Task.await_many(tasks, 240_000)
    first = sequential(ctx.worldgen, [a, b])
    second = sequential(ctx.worldgen, [b, a])

    assert {ours_a, ours_b} in [{first[a], first[b]}, {second[a], second[b]}]
  end

  test "decorations survive restarts of every owner", ctx do
    want = sequential(ctx.worldgen, [ctx.key, east(ctx.key)])
    assert_same(full(ctx.key), want[ctx.key])
    stop(ctx.keys)
    assert_same(full(east(ctx.key)), want[east(ctx.key)])
    stop(ctx.keys)
    # The first region's final chunks come back from its log.
    assert_same(full(ctx.key), want[ctx.key])
  end

  test "handing over drops the images and refuses later requests", ctx do
    _ = full(ctx.key)
    :ok = Proto.handed_over(ctx.key)
    await(fn -> map_size(:sys.get_state(pid(ctx.key)).chunks) == 0 end)
    assert Proto.full_chunks(ctx.key) == {:error, :handed_over}
    stop(ctx.keys)
    assert Proto.full_chunks(ctx.key) == {:error, :handed_over}
  end

  describe "crashes" do
    # The last participant in key order (the region north-east... south-east).
    defp last(key), do: key |> TestScope.neighborhood() |> Enum.max()

    test "a coordinator dying before its commit leaves no lock behind", ctx do
      want = sequential(ctx.worldgen, [ctx.key])
      participant = pid(last(ctx.key))
      coordinator = pid(ctx.key)
      :ok = :sys.suspend(participant)
      task = Task.async(fn -> Proto.full_chunks(ctx.key, 120_000) end)

      # Earlier participants hold durable locks while the last one stalls.
      first = Enum.min(TestScope.neighborhood(ctx.key))
      await(fn -> map_size(:sys.get_state(pid(first)).grants) == 1 end)
      Process.unlink(task.pid)
      TestScope.kill(coordinator)
      :ok = :sys.resume(participant)
      Task.shutdown(task, :brutal_kill)

      # They ask the coordinator's next incarnation, which never committed.
      for key <- TestScope.neighborhood(ctx.key), key != ctx.key do
        await(fn -> map_size(:sys.get_state(pid(key)).grants) == 0 end)
      end

      assert_same(full(ctx.key), want[ctx.key])
    end

    test "a coordinator dying after its commit delivers its parts on restart", ctx do
      want = sequential(ctx.worldgen, [ctx.key, east(ctx.key)])
      coordinator = pid(ctx.key)
      participant = pid(last(ctx.key))
      writer = :sys.get_state(participant).log
      task = Task.async(fn -> Proto.full_chunks(ctx.key, 120_000) end)
      # Once the last participant holds its lock, the coordinator stops before
      # its decoration lands and that participant's writer stalls, so its part
      # cannot be applied: the commit leaves an outbox entry.
      await(fn -> map_size(:sys.get_state(participant).grants) == 1 end)
      :ok = :sys.suspend(coordinator)
      :ok = :sys.suspend(writer)
      :ok = :sys.resume(coordinator)
      await(fn -> map_size(:sys.get_state(coordinator).outbox) == 1 end)
      Process.unlink(task.pid)
      TestScope.kill(coordinator)
      Task.shutdown(task, :brutal_kill)
      :ok = :sys.resume(writer)

      # The restarted coordinator delivers the committed part.
      assert_same(full(ctx.key), want[ctx.key])
      await(fn -> map_size(:sys.get_state(participant).grants) == 0 end)
      assert_same(full(east(ctx.key)), want[east(ctx.key)])
    end

    test "a participant dying while it holds a lock keeps it until the part arrives", ctx do
      want = sequential(ctx.worldgen, [ctx.key, east(ctx.key)])
      coordinator = pid(ctx.key)
      victim = pid(Enum.min(TestScope.neighborhood(ctx.key)))
      task = Task.async(fn -> Proto.full_chunks(ctx.key, 120_000) end)
      await(fn -> map_size(:sys.get_state(victim).grants) == 1 end)
      :ok = :sys.suspend(coordinator)
      TestScope.kill(victim)
      :ok = :sys.resume(coordinator)

      assert_same(Task.await(task, 120_000) |> elem(1), want[ctx.key])
      # The victim's next incarnation recovered its lock and applied the part.
      await(fn -> map_size(:sys.get_state(pid(Enum.min(TestScope.neighborhood(ctx.key)))).grants) == 0 end)
      assert_same(full(east(ctx.key)), want[east(ctx.key)])
    end
  end
end
