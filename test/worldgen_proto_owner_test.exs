defmodule Valimc.WorldgenProtoOwnerTest do
  @moduledoc """
  Proto owners and the finalize transaction (VMC-025d2): regions become final
  across region borders exactly as one decoration of the same chunks in the
  same order, concurrent neighbours serialize (as some order of them), and
  decorations survive restarts and crashes at each step of the transaction.
  """
  # Serial: finalize transactions saturate the worldgen workers and dirty schedulers.
  use ExUnit.Case, async: false
  @moduletag :slow
  alias Valimc.{Native, TestScope}
  alias Valimc.World.Generator
  alias Valimc.Worldgen.Proto

  @seed 20_261_020
  @source "minecraft:overworld"
  @moduletag timeout: 300_000

  setup do
    nonce = System.unique_integer([:positive])
    # One region for every test (serial): each gets a fresh world, and the
    # expected chunks are computed once.
    key = {-20_000, -7_000}
    base = Path.join(System.tmp_dir!(), "valimc-proto-#{nonce}")
    File.mkdir_p!(base)

    :ok =
      Valimc.World.Spec.write(base, %{"type" => "vanilla", "seed" => @seed, "features" => true})

    keys = TestScope.neighborhood(key, 3)
    TestScope.isolate(keys, world_path: base)

    on_exit(fn ->
      stop(keys)
      File.rm_rf(base)
    end)

    {:ok, worldgen} = Generator.worldgen(@seed)
    %{key: key, keys: keys, base: base, worldgen: worldgen}
  end

  # Until none is left: an owner still running a transaction starts the
  # owners it asks, so one killed earlier in a pass may be back (with this
  # test's world, into the next test).
  defp stop(keys) do
    pids =
      for key <- keys,
          {pid, _} <- Registry.lookup(Valimc.ProtoRegistry, key),
          Process.alive?(pid),
          do: pid

    if pids != [] do
      Enum.each(pids, &TestScope.kill/1)
      stop(keys)
    end
  end

  defp east({x, z}), do: {x + 1, z}

  # What finalizing `regions` one after the other gives: their 12 × 12 areas'
  # terrain, then each region's undecorated 10 × 10 decorated Z outer, X inner.
  defp sequential(worldgen, regions) do
    case :persistent_term.get({__MODULE__, regions}, nil) do
      nil ->
        result = compute_sequential(worldgen, regions)
        :persistent_term.put({__MODULE__, regions}, result)
        result

      result ->
        result
    end
  end

  defp compute_sequential(worldgen, regions) do
    images = area_terrain(worldgen, regions)

    {images, _} =
      Enum.reduce(regions, {images, MapSet.new()}, fn region, {images, decorated} ->
        order = Enum.reject(Proto.around(region, 1), &MapSet.member?(decorated, &1))

        {:ok, {touched, 0}} =
          Native.worldgen_proto_decorate(worldgen, @source, Map.values(images), order, true)

        touched = Map.new(touched, fn {x, z, image} -> {{x, z}, image} end)
        {Map.merge(images, touched), MapSet.union(decorated, MapSet.new(order))}
      end)

    Map.new(regions, fn region ->
      own = Enum.map(Proto.chunks_of(region), &images[&1])
      {:ok, full} = Native.worldgen_proto_full(worldgen, own, Generator.protocol_biomes())
      {region, full}
    end)
  end

  # The terrain of the regions' 12 × 12 areas, computed once per set.
  defp area_terrain(worldgen, regions) do
    id = {__MODULE__, :terrain, Enum.sort(regions)}

    case :persistent_term.get(id, nil) do
      nil ->
        area = regions |> Enum.flat_map(&Proto.around(&1, 2)) |> Enum.uniq()
        images = terrain(worldgen, area)
        :persistent_term.put(id, images)
        images

      images ->
        images
    end
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

  # The owner holds one lock and it is durable (prepared).
  defp prepared?(pid) do
    state = :sys.get_state(pid)

    map_size(state.grants) == 1 and map_size(state.writes) == 0 and
      Enum.all?(state.grants, fn {_, grant} -> grant.durable end)
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

  # VMC-075: the live region asks for a few chunks at a time.
  test "finalizing some chunks decorates the chunks within one of them, in order, over terrain",
       ctx do
    # Two batches at the region's corner (their areas reach three neighbours),
    # the second within two of the first.
    {cx, cz} = hd(Proto.chunks_of(ctx.key))
    first = [{cx, cz}, {cx + 1, cz}]
    second = [{cx + 3, cz + 1}]
    {:ok, ours_first} = Proto.full_chunks(ctx.key, first, 120_000)
    {:ok, ours_second} = Proto.full_chunks(ctx.key, second, 120_000)

    images = terrain(ctx.worldgen, Proto.within(first ++ second, 2))

    decorate = fn images, order ->
      {:ok, {touched, 0}} =
        Native.worldgen_proto_decorate(ctx.worldgen, Map.values(images), order)

      Map.merge(images, Map.new(touched, fn {x, z, image} -> {{x, z}, image} end))
    end

    order = Proto.within(first, 1)
    images = decorate.(images, order)
    images = decorate.(images, Proto.within(second, 1) -- order)

    for {chunks, ours} <- [{first, ours_first}, {second, ours_second}] do
      {:ok, want} =
        Native.worldgen_proto_full(
          ctx.worldgen,
          Enum.map(chunks, &images[&1]),
          Generator.protocol_biomes()
        )

      assert ours == want
    end

    # Only what the two batches needed was decorated; the rest of the region
    # is still terrain or not generated.
    state = :sys.get_state(pid(ctx.key))
    decorated = for {chunk, {:decorated, _}} <- state.chunks, do: chunk

    assert Enum.sort(decorated) ==
             Enum.sort(
               Enum.filter(
                 Proto.within(first ++ second, 1),
                 &(Valimc.World.region_key(&1) == ctx.key)
               )
             )

    assert MapSet.new(first ++ second) == state.final
  end

  test "handing over drops the images and refuses later requests", ctx do
    _ = full(ctx.key)
    :ok = Proto.handed_over(ctx.key)
    owner = pid(ctx.key)
    await(fn -> map_size(:sys.get_state(owner).chunks) == 0 end)
    assert Proto.full_chunks(ctx.key) == {:error, :handed_over}
    # Its work done, the owner retires within seconds (VMC-074), not minutes.
    watch = Process.monitor(owner)
    assert_receive {:DOWN, ^watch, :process, ^owner, :normal}, 30_000
    assert Proto.full_chunks(ctx.key) == {:error, :handed_over}
    stop(ctx.keys)
    assert Proto.full_chunks(ctx.key) == {:error, :handed_over}
  end

  describe "crashes" do
    # The last participant in key order (the region north-east... south-east).
    defp last(key), do: key |> TestScope.neighborhood() |> Enum.max()

    test "a coordinator dying before its commit leaves no lock behind", ctx do
      want = sequential(ctx.worldgen, [ctx.key])
      writer = :sys.get_state(pid(last(ctx.key))).log
      coordinator = pid(ctx.key)
      :ok = :sys.suspend(writer)
      task = Task.async(fn -> Proto.full_chunks(ctx.key, 120_000) end)

      # The other participants' locks are durable while the last one's
      # prepare stalls, so the coordinator cannot commit.
      first = Enum.min(TestScope.neighborhood(ctx.key))
      await(fn -> prepared?(pid(first)) end)
      Process.unlink(task.pid)
      TestScope.kill(coordinator)
      :ok = :sys.resume(writer)
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
      # Once the last participant's lock is durable (the decoration is still
      # running), its writer stalls, so its part cannot be applied: the commit
      # leaves an outbox entry.
      await(fn -> prepared?(participant) end)
      :ok = :sys.suspend(writer)
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
      await(fn -> prepared?(victim) end)
      :ok = :sys.suspend(coordinator)
      TestScope.kill(victim)
      :ok = :sys.resume(coordinator)

      assert_same(Task.await(task, 120_000) |> elem(1), want[ctx.key])
      # The victim's next incarnation recovered its lock and applied the part.
      await(fn ->
        map_size(:sys.get_state(pid(Enum.min(TestScope.neighborhood(ctx.key)))).grants) == 0
      end)

      assert_same(full(east(ctx.key)), want[east(ctx.key)])
    end
  end
end
