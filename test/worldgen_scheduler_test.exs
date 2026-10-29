defmodule Valimc.WorldgenSchedulerTest do
  @moduledoc """
  The generation scheduler (VMC-077n): full chunks equal one decoration of the
  chunks it numbered, in that order, structures included, whatever requests
  overlap; a graceful restart resumes from the snapshot, starts included; a
  chunk lost after it was handed over is made again alone; terrain-only worlds
  are final after terrain; a failed job fails its chunk instead of retrying; a
  chunk on its way to a region is not sent again (VMC-077u).
  """
  # Serial: the scheduler's jobs fill the generation pool.
  use ExUnit.Case, async: false
  @moduletag :slow
  @moduletag timeout: 300_000
  alias Valimc.Native
  alias Valimc.World.Blocks
  alias Valimc.Worldgen.Generator
  alias Valimc.Worldgen.{Frontier, Scheduler}

  @seed 20_261_020
  @source "minecraft:overworld"

  setup do
    previous = Application.get_env(:valimc, :generation_order_log)
    Application.put_env(:valimc, :generation_order_log, true)
    base = Path.join(System.tmp_dir!(), "valimc-scheduler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    :ok =
      Valimc.World.Spec.write(base, %{"type" => "vanilla", "seed" => @seed, "features" => true})

    on_exit(fn ->
      stop(base)
      Application.put_env(:valimc, :generation_order_log, previous)
      File.rm_rf(base)
    end)

    {:ok, worldgen} = Generator.worldgen(@seed)
    %{base: base, worldgen: worldgen}
  end

  # Gracefully: the scheduler writes its snapshot.
  defp stop(base) do
    for {pid, _} <- Registry.lookup(Valimc.Worldgen.Schedulers, {base, :overworld}) do
      DynamicSupervisor.terminate_child(Valimc.Worldgen.SchedulerSupervisor, pid)
    end
  end

  defp full(base, chunks) do
    {:ok, full} = Scheduler.full_chunks(base, :overworld, chunks, 240_000)
    full
  end

  # `chunks` made full as one decoration of `order` over fresh terrain makes them.
  defp reference(worldgen, order, chunks) do
    area = Enum.flat_map(order, &Frontier.around(&1, 1))
    {xs, zs} = {Enum.map(area, &elem(&1, 0)), Enum.map(area, &elem(&1, 1))}
    {x0, z0} = {Enum.min(xs), Enum.min(zs)}
    size = max(Enum.max(xs) - x0, Enum.max(zs) - z0) + 1
    {:ok, cells} = Native.gen_reference(worldgen, @source, {x0, z0}, size, order, true)
    cell = fn {x, z} -> Enum.at(cells, (z - z0) * size + (x - x0)) end

    Enum.map(chunks, fn chunk ->
      {:ok, full} = Native.gen_full(worldgen, cell.(chunk), Generator.protocol_biomes())
      %{full | image: Map.fetch!(Blocks.lit_images(%{chunk => full.image}, true), chunk)}
    end)
  end

  defp assert_same(ours, want) do
    assert length(ours) == length(want)

    for {a, b} <- Enum.zip(ours, want) do
      assert {a.x, a.z} == {b.x, b.z}
      assert a.image == b.image, "chunk #{a.x}, #{a.z} differs"
      assert a == b
    end
  end

  test "requests one after the other equal one decoration in the order they ran", ctx do
    first = [{-40, 12}, {-39, 12}]
    second = [{-36, 13}]
    ours = full(ctx.base, first) ++ full(ctx.base, second)
    order = Scheduler.order(ctx.base, :overworld)
    # The first request's undecorated chunks within 1 ran before the second's.
    decorated = first |> Enum.flat_map(&Frontier.around(&1, 1)) |> Enum.uniq()
    assert Enum.sort(Enum.take(order, 12)) == Enum.sort(decorated)
    assert_same(ours, reference(ctx.worldgen, order, first ++ second))
  end

  test "overlapping concurrent requests equal the decoration of the order they got", ctx do
    a = [{300, -20}, {301, -20}]
    b = [{302, -19}, {302, -18}]
    tasks = Enum.map([a, b], fn chunks -> Task.async(fn -> full(ctx.base, chunks) end) end)
    [ours_a, ours_b] = Task.await_many(tasks, 240_000)
    order = Scheduler.order(ctx.base, :overworld)
    assert_same(ours_a ++ ours_b, reference(ctx.worldgen, order, a ++ b))
  end

  test "a graceful restart resumes from the snapshot", ctx do
    first = [{-40, 12}, {-39, 12}]
    second = [{-38, 13}]
    ours_first = full(ctx.base, first)
    before = Scheduler.order(ctx.base, :overworld)
    stop(ctx.base)
    snapshot = Path.join(ctx.base, "generation.snapshot")
    assert File.exists?(snapshot)

    ours_second = full(ctx.base, second)
    refute File.exists?(snapshot)
    order = before ++ Scheduler.order(ctx.base, :overworld)
    assert_same(ours_first ++ ours_second, reference(ctx.worldgen, order, first ++ second))
  end

  # Seed 20261020's mineshaft starting at chunk (8, -8) has a spider corridor at
  # x 151..153, y -44..-42, z -117..-108, in chunks (9, -8) and (9, -7).
  # Vanilla places its spawner in the first chunk with a free spot, once.
  test "a start's once-only piece stays placed across a restart", ctx do
    _ = full(ctx.base, [{9, -9}])
    stop(ctx.base)
    _ = full(ctx.base, [{9, -6}])

    spawners =
      for %{block_entities: entities} <- full(ctx.base, [{9, -8}, {9, -7}]),
          %{position: {x, y, z}, kind: "minecraft:mob_spawner"} <- entities,
          x in 151..153 and y in -44..-42 and z in -117..-108,
          do: z

    assert [z] = spawners
    assert z < -112
  end

  test "a chunk lost after it was handed over is made again alone", ctx do
    chunk = {-1_000, 400}
    [_] = full(ctx.base, [chunk])
    :ok = Scheduler.handed_over(ctx.base, :overworld, [chunk])
    [again] = full(ctx.base, [chunk])
    {x, z} = chunk
    {:ok, cells} = Native.gen_reference(ctx.worldgen, @source, {x - 1, z - 1}, 3, [chunk], true)
    {:ok, want} = Native.gen_full(ctx.worldgen, Enum.at(cells, 4), Generator.protocol_biomes())
    assert again.image == Map.fetch!(Blocks.lit_images(%{chunk => want.image}, true), chunk)
  end

  test "a terrain-only world's chunks are final after terrain", ctx do
    base = ctx.base <> "-terrain"
    :ok = Valimc.World.Spec.write(base, %{"type" => "vanilla", "seed" => @seed})

    on_exit(fn ->
      stop(base)
      File.rm_rf(base)
    end)

    chunks = [{5, 5}, {6, 5}]
    ours = full(base, chunks)
    want = Blocks.lit_images(Generator.columns({:vanilla, @seed}, chunks), true)
    assert Enum.map(ours, & &1.image) == Enum.map(chunks, &want[&1])
    assert Scheduler.stats(base, :overworld).decorated == 0
  end

  test "a chunk still on its way to a region is not sent twice", ctx do
    base = ctx.base <> "-flight"
    :ok = Valimc.World.Spec.write(base, %{"type" => "vanilla", "seed" => @seed})

    on_exit(fn ->
      stop(base)
      File.rm_rf(base)
    end)

    requester = {self(), {0, 0}}
    {:ok, _} = Scheduler.want(base, :overworld, requester, 1, %{{3, 3} => false})
    assert_receive {:generated, scheduler, [{{0, 0}, 1, [%{x: 3, z: 3}]}]}, 60_000

    # Wanted again before the region read it (its mailbox lags its tickets):
    # it is on its way. A section loaded again (a new epoch) gets it again.
    {:ok, _} = Scheduler.want(base, :overworld, requester, 1, %{{3, 3} => false})
    assert Scheduler.stats(base, :overworld).wanted == 0
    Scheduler.delivered(scheduler)
    {:ok, _} = Scheduler.want(base, :overworld, requester, 2, %{{3, 3} => false})
    assert_receive {:generated, ^scheduler, [{{0, 0}, 2, [%{x: 3, z: 3}]}]}, 60_000

    # One delivery unacknowledged: what finishes next waits, and goes in
    # one delivery, nearest first, once one is acknowledged (VMC-077w).
    :ok = Scheduler.focus(base, :overworld, self(), {6, 6}, nil)
    wanted = %{{9, 9} => false, {6, 6} => false, {7, 6} => false}
    {:ok, _} = Scheduler.want(base, :overworld, requester, 2, wanted)
    eventually(fn -> Scheduler.stats(base, :overworld).wanted == 0 end)
    refute_received {:generated, _, _}
    # They keep the epoch they were made for, whatever the section's is now.
    {:ok, _} = Scheduler.want(base, :overworld, requester, 3, %{})
    Scheduler.delivered(scheduler)
    assert_receive {:generated, ^scheduler, [{{0, 0}, 2, fulls}]}, 60_000
    assert Enum.map(fulls, &{&1.x, &1.z}) == [{6, 6}, {7, 6}, {9, 9}]

    # An already-ready wide view still installs at most eight chunks per turn.
    chunks = for x <- 0..4, z <- 0..3, do: {x, z}
    _ = full(base, chunks)
    {:ok, _} = Scheduler.want(base, :overworld, requester, 4, Map.new(chunks, &{&1, false}))
    eventually(fn -> Scheduler.stats(base, :overworld).wanted == 0 end)
    refute_received {:generated, _, _}

    got =
      Enum.reduce(1..3, [], fn _, got ->
        Scheduler.delivered(scheduler)
        assert_receive {:generated, ^scheduler, deliveries}, 60_000
        fulls = Enum.flat_map(deliveries, fn {_, 4, list} -> list end)
        assert length(fulls) <= 8
        refute_received {:generated, _, _}
        Enum.map(fulls, &{&1.x, &1.z}) ++ got
      end)

    assert Enum.sort(got) == Enum.sort(chunks)
  end

  defp eventually(check, tries \\ 600) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  test "with few proto chunks in memory, dropped and spilled ones change nothing", ctx do
    previous = Application.get_env(:valimc, :worldgen_proto_cells)
    Application.put_env(:valimc, :worldgen_proto_cells, 8)
    on_exit(fn -> Application.put_env(:valimc, :worldgen_proto_cells, previous) end)

    first = [{-40, 12}, {-39, 12}]
    # Beside the first: its decorations read the first's spilled chunks back.
    second = [{-37, 12}]
    ours = full(ctx.base, first) ++ full(ctx.base, second)

    # The memory gauge counts a proto chunk's states at least (384 × 256 of them).
    {:ok, [cell]} = Scheduler.cells(ctx.base, :overworld, [{-40, 12}])
    assert {:ok, bytes} = Native.gen_cells_bytes([cell])
    assert bytes >= 384 * 256 * 2 and bytes < 2 * 384 * 256 * 2
    # Every terrain chunk here was decorated into: all spill, none is dropped.
    eventually(fn -> Scheduler.stats(ctx.base, :overworld).spills > 0 end)
    assert Scheduler.stats(ctx.base, :overworld).spilled > 0
    order = Scheduler.order(ctx.base, :overworld)
    assert_same(ours, reference(ctx.worldgen, order, first ++ second))

    # A graceful restart snapshots spilled chunks too, and restores them spilled.
    stop(ctx.base)
    third = [{-35, 12}]
    ours_third = full(ctx.base, third)
    order = order ++ Scheduler.order(ctx.base, :overworld)
    assert_same(ours_third, reference(ctx.worldgen, order, third))
  end

  test "a failed job fails its chunk and the wants that need it, once" do
    spec = %{
      kind: :noise,
      seed: @seed,
      noise_settings: @source,
      biome_source: @source,
      facts: nil,
      structures: false
    }

    f = Frontier.want(Frontier.new(spec), :region, %{{0, 0} => false, {9, 9} => false})
    {jobs, f} = Frontier.next(f, 64)
    terrain = Enum.find(jobs, &(&1.chunk == {1, 1}))
    {f, events} = Frontier.done(f, terrain.ref, {:error, :boom})
    assert events == [{:failed, [:region], [{0, 0}], :boom}]

    f = Enum.reduce(jobs, f, &Frontier.cancel(&2, &1.ref))
    {again, _} = Frontier.next(f, 64)
    refute Enum.any?(again, &(&1.chunk == {1, 1}))
    assert Enum.any?(again, &(&1.chunk == {9, 9}))
  end
end
