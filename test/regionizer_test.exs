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

    # The ends stay wanted; the bridge only for a moment.
    for key <- ends do
      {:ok, owner} = Valimc.TestWorld.owner(key)
      TestScope.simulate(owner, key)
    end

    {:ok, _} = Valimc.TestWorld.owner(bridge)
    :ok = Regionizer.settle(:overworld)
    assert same_group?(hd(ends), List.last(ends))

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
end
