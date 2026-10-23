defmodule Valimc.GrowthTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks
  alias Valimc.TestScope
  alias Valimc.World.Region

  # Growth's rules are checked tick by tick against the oracle (stage
  # `growth`); this is their wiring in a stepped owner: the sampler hands
  # the growing blocks to the rules, which read the owner's light and water.
  setup do
    nonce = System.unique_integer([:positive])
    key = {76_000 + rem(nonce, 3_333) * 3, 1830}
    base = Path.join(System.tmp_dir!(), "valimc-growth-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual, random_tick_speed: 4096)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    {:ok, owner} = Valimc.TestWorld.owner(key)
    TestScope.simulate(owner, key)
    %{owner: owner, origin: {rx * span + 40, 63, rz * span + 40}}
  end

  defp blocks(owner, positions) do
    {:ok, %{blocks: blocks}} = Region.observe_blocks(owner, positions)
    blocks
  end

  defp name(state), do: Blocks.name(Blocks.block_id(state))
  defp value(state, property), do: Map.new(Blocks.properties(state))[property]

  test "crops and sugar cane grow; farmland away from water dries to dirt",
       %{owner: owner, origin: {x, y, z}} do
    farmland = {x + 1, y, z}
    wheat = {x + 1, y + 1, z}
    cane = {x, y + 1, z + 1}
    dry = {x + 10, y, z}

    edits = %{
      {x, y, z} => Blocks.default_state("water"),
      farmland => Blocks.default_state("farmland"),
      wheat => Blocks.default_state("wheat"),
      {x, y, z + 1} => Blocks.default_state("sand"),
      cane => Blocks.default_state("sugar_cane"),
      dry => Blocks.default_state("farmland")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    {:ok, _} = Region.step(owner, 300)

    grown =
      blocks(owner, [farmland, wheat, cane, {x, y + 2, z + 1}, {x, y + 3, z + 1}, dry])

    assert value(grown[farmland], "moisture") == "7"
    assert value(grown[wheat], "age") == "7"
    assert name(grown[{x, y + 2, z + 1}]) == "sugar_cane"
    assert name(grown[{x, y + 3, z + 1}]) == "sugar_cane"
    assert name(grown[dry]) == "dirt"
  end

  test "a sapling grows into its tree", %{owner: owner, origin: {x, y, z}} do
    sapling = {x, y + 1, z}
    stage = Blocks.state("oak_sapling", %{"stage" => "1"})
    {:ok, observed} = Region.observe_blocks(owner, [sapling])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{sapling => stage})

    # The tree grows in a task once a tick decides it; step until it lands.
    Valimc.TestWait.until(fn ->
      {:ok, _} = Region.step(owner, 1)
      name(blocks(owner, [sapling])[sapling]) == "oak_log"
    end)

    # A trunk of at least four logs over the grass, which became dirt.
    trunk = for dy <- 1..4, do: {x, y + dy, z}
    assert Enum.all?(blocks(owner, trunk), fn {_, state} -> name(state) == "oak_log" end)
    assert name(blocks(owner, [{x, y, z}])[{x, y, z}]) == "dirt"
  end

  test "bone meal grows a crop, passes on stone", %{owner: owner, origin: {x, y, z}} do
    wheat = {x + 3, y + 1, z}

    edits = %{
      {x + 3, y, z} => Blocks.default_state("farmland"),
      wheat => Blocks.default_state("wheat")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)

    assert {:ok, 1} = Region.bucket(owner, {:bone_meal, wheat})
    assert String.to_integer(value(blocks(owner, [wheat])[wheat], "age")) in 2..5
    assert {:ok, 0} = Region.bucket(owner, {:bone_meal, {x + 3, y - 2, z}})
  end
end
