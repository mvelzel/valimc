defmodule Valimc.RegionizerTest do
  @moduledoc """
  The regionizer (VMC-077j2): loaded sections within three sections of each
  other share a group process, farther ones do not, and a group splits once
  enough of its sections unloaded and the rest fell apart.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World.{Region, Regionizer}

  setup do
    nonce = System.unique_integer([:positive])
    # A row of sections, spaced so tests of other worlds stay out of reach.
    origin = {120_000 + rem(nonce, 1_000) * 40, 2100}
    base = Path.join(System.tmp_dir!(), "valimc-regionizer-#{nonce}")
    keys = for dx <- 0..12, do: {elem(origin, 0) + dx, 2100}
    TestScope.isolate(keys, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for key <- keys,
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{origin: origin, base: base}
  end

  defp at({x, z}, dx), do: {x + dx, z}

  # The group of `key`, or nil while its route changes.
  defp group(key) do
    case Valimc.TestWorld.owner(key) do
      {:ok, {pid, _}} -> pid
      {:error, {:retry, _}} -> nil
    end
  end

  defp same_group?(a, b), do: same(group(a), group(b), true)
  defp separate?(a, b), do: same(group(a), group(b), false)

  defp same(nil, _, _), do: false
  defp same(_, nil, _), do: false
  defp same(a, b, equal), do: a == b == equal

  test "sections within three of each other share a group; farther ones do not", ctx do
    {:ok, _} = Valimc.TestWorld.owner(at(ctx.origin, 0))
    {:ok, _} = Valimc.TestWorld.owner(at(ctx.origin, 3))
    {:ok, _} = Valimc.TestWorld.owner(at(ctx.origin, 8))
    :ok = Regionizer.settle(:overworld)
    assert same_group?(at(ctx.origin, 0), at(ctx.origin, 3))
    assert separate?(at(ctx.origin, 0), at(ctx.origin, 8))

    # A section between them brings both groups into one; their state comes along.
    stone = BlockRegistry.default_state("stone")
    {x, z} = at(ctx.origin, 8)
    position = {x * 128 + 3, 70, z * 128 + 3}
    {:ok, owner} = Valimc.TestWorld.owner(at(ctx.origin, 8))
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{position => stone})
    # Section 5 brings two groups into the largest, one after the other.
    {:ok, _} = Valimc.TestWorld.owner(at(ctx.origin, 5))
    :ok = Regionizer.settle(:overworld)
    assert same_group?(at(ctx.origin, 0), at(ctx.origin, 8))

    assert Region.sections(group(at(ctx.origin, 0))) ==
             Enum.sort(for dx <- [0, 3, 5, 8], do: at(ctx.origin, dx))

    assert Valimc.TestBlocks.get(position) == stone

    groups = Regionizer.groups(:overworld)
    assert Enum.count(groups, fn {_, keys} -> at(ctx.origin, 0) in keys end) == 1
  end

  test "a group whose bridge unloads splits into its pieces", ctx do
    TestScope.isolate(
      for(dx <- 0..12, do: at(ctx.origin, dx)),
      region_ticks: :timer,
      region_unload_delay_ms: 0
    )

    ends = [at(ctx.origin, 0), at(ctx.origin, 6)]
    bridge = at(ctx.origin, 3)

    # The ends stay wanted; the bridge until the group has formed.
    for key <- ends do
      {:ok, owner} = Valimc.TestWorld.owner(key)
      TestScope.simulate(owner, key)
    end

    {:ok, held} = Valimc.TestWorld.owner(bridge)
    TestScope.simulate(held, bridge)
    :ok = Regionizer.settle(:overworld)
    assert same_group?(hd(ends), List.last(ends))
    {:ok, owner} = Valimc.TestWorld.owner(bridge)
    Region.ticket(owner, bridge, :forced, nil, [])

    # The bridge unloads on its group's tick; the regionizer splits the group
    # when it handles that report.
    assert Valimc.TestWait.until(
             fn ->
               not Enum.any?(Regionizer.groups(:overworld), fn {_, keys} -> bridge in keys end)
             end,
             30_000
           )

    assert separate?(hd(ends), List.last(ends))
  end

  # The final VMC-077 client run: one tick unloads a bridge and a section of
  # the piece that splits off; the split, decided on the first report, names
  # the second section too.
  test "a split decided before a second unload's report still splits", ctx do
    TestScope.isolate(
      for(dx <- 0..12, do: at(ctx.origin, dx)),
      region_ticks: :timer,
      region_unload_delay_ms: 0
    )

    kept = for dx <- [0, 1, 2, 8], do: at(ctx.origin, dx)
    [bridge, far] = [at(ctx.origin, 5), at(ctx.origin, 9)]

    for key <- kept ++ [bridge, far] do
      {:ok, owner} = Valimc.TestWorld.owner(key)
      TestScope.simulate(owner, key)
    end

    :ok = Regionizer.settle(:overworld)
    assert same_group?(hd(kept), List.last(kept))
    groups = Regionizer.groups(:overworld)
    # Hold the regionizer while both go, so it reads the bridge's report first.
    regionizer = GenServer.whereis({:via, Registry, {Valimc.Regionizers, :overworld}})
    :sys.suspend(regionizer)

    try do
      # Both go on the group's next tick, in key order: the bridge first. A
      # section leaves the group's list once its report is sent.
      {:ok, {pid, _}} = Valimc.TestWorld.owner(bridge)

      for key <- [bridge, far] do
        {:ok, owner} = Valimc.TestWorld.owner(key)
        Region.ticket(owner, key, :forced, nil, [])
      end

      assert Valimc.TestWait.until(
               fn ->
                 sections = Region.sections(pid)
                 bridge not in sections and far not in sections
               end,
               30_000
             )
    after
      :sys.resume(regionizer)
    end

    :ok = Regionizer.settle(:overworld)
    assert separate?(at(ctx.origin, 0), at(ctx.origin, 8))
    assert same_group?(at(ctx.origin, 0), at(ctx.origin, 2))

    # Every group the regionizer knows holds exactly what it says, nothing
    # unloaded among them, and no empty group was left behind.
    for {pid, keys} <- Regionizer.groups(:overworld), Enum.any?(keys, &(&1 in kept)) do
      assert Enum.sort(keys) == Region.sections(pid)
      refute bridge in keys or far in keys
    end

    assert map_size(Regionizer.groups(:overworld)) <= map_size(groups) + 1
  end

  test "a section gone before its load report is read joins no groups", ctx do
    TestScope.isolate(
      for(dx <- 0..12, do: at(ctx.origin, dx)),
      region_ticks: :timer,
      region_unload_delay_ms: 0
    )

    ends = [at(ctx.origin, 0), at(ctx.origin, 6)]
    bridge = at(ctx.origin, 3)

    for key <- ends do
      {:ok, owner} = Valimc.TestWorld.owner(key)
      TestScope.simulate(owner, key)
    end

    :ok = Regionizer.settle(:overworld)
    regionizer = GenServer.whereis({:via, Registry, {Valimc.Regionizers, :overworld}})
    :sys.suspend(regionizer)

    try do
      # Wanted by nobody: it loads and unloads before the regionizer reads of
      # it. Its group reports the unload, then stops (it has nothing left).
      {:ok, {group, _}} = Valimc.TestWorld.owner(bridge)
      monitor = Process.monitor(group)
      assert_receive {:DOWN, ^monitor, :process, ^group, _}, 30_000
    after
      :sys.resume(regionizer)
    end

    :ok = Regionizer.settle(:overworld)
    assert separate?(hd(ends), List.last(ends))
    refute Enum.any?(Regionizer.groups(:overworld), fn {_, keys} -> bridge in keys end)
  end
end
