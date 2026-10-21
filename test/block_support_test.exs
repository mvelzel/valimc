defmodule Valimc.BlockSupportTest do
  use ExUnit.Case, async: true
  alias Valimc.Block.Support
  alias Valimc.Protocol.ItemTypes
  alias Valimc.Registry.Blocks
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  # Survival and update rules are compared by the support oracle stage; these tests
  # cover the owner's reads, drops and persistence.
  @air Blocks.default_state("air")
  @stone Blocks.default_state("stone")
  @dirt Blocks.default_state("dirt")
  @short_grass Blocks.default_state("short_grass")
  @poppy Blocks.default_state("poppy")
  @torch Blocks.default_state("torch")
  @cane Blocks.default_state("sugar_cane")
  @lower Blocks.state("tall_grass", %{"half" => "lower"})
  @at {0, 64, 0}

  test "a neighbour outside the readable region never breaks a block" do
    unknown = fn _ -> nil end
    assert Support.survives?(@at, @short_grass, unknown)
    # Updates from above and below (vanilla direction order: down 0, up 1).
    assert Support.update(@at, @lower, [1, 0], unknown) == :keep
    refute Support.breaks?(@at, @cane, unknown)
  end

  describe "in a region owner" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {76_000 + rem(nonce, 3_333) * 3, 1830}
      base = Path.join(System.tmp_dir!(), "valimc-support-#{nonce}")
      TestScope.isolate(key, world_path: base, region_ticks: :manual, random_tick_speed: 0)

      on_exit(fn ->
        for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
            {pid, _} <- Registry.lookup(reg, key),
            do: TestScope.kill(pid)

        File.rm_rf(base)
      end)

      {rx, rz} = key
      span = Valimc.config(:region_size) * 16
      {:ok, owner} = World.owner(key)
      TestScope.simulate(owner, key)
      %{owner: owner, key: key, base: base, origin: {rx * span + 40, 100, rz * span + 40}}
    end

    defp blocks(owner, positions) do
      {:ok, %{blocks: blocks}} = Region.observe_blocks(owner, positions)
      Enum.map(positions, &Map.fetch!(blocks, &1))
    end

    defp set(owner, edits) do
      {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
      {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    end

    defp items({pid, _}) do
      for {_, entry} <- :sys.get_state(pid).resource.items.entries,
          do: {entry.stack.item_id, entry.stack.count}
    end

    # Waits until every queued commit is durable.
    defp settle({pid, _}, _budget \\ nil) do
      # A write still in flight answers busy; the flush itself must then succeed.
      Valimc.TestWait.until(fn -> Region.flush(pid) == :ok end)
      :ok
    end

    test "a flower and a torch on a removed block break on the next tick and drop",
         %{owner: owner, origin: {x, y, z} = soil} do
      flower = {x, y + 1, z}
      torch = {x, y - 1, z}
      side = {x + 1, y, z}
      set(owner, %{soil => @dirt, flower => @poppy, torch => @torch, side => @torch})
      set(owner, %{{x, y - 2, z} => @stone, {x + 1, y - 1, z} => @stone})
      set(owner, %{soil => @air})
      assert blocks(owner, [flower]) == [@poppy]

      {:ok, _} = Region.step(owner, 1)
      settle(owner)
      # Both torches stand on stone: the removed block is above one and beside the other.
      assert blocks(owner, [flower, torch, side]) == [@air, @torch, @torch]
      assert items(owner) == [{ItemTypes.id("poppy"), 1}]

      # The drop pops near the block centre and is launched upwards, not left hovering.
      [entity] =
        for {_, entry} <- :sys.get_state(elem(owner, 0)).resource.items.entries, do: entry.entity

      assert abs(entity.x - (x + 0.5)) <= 0.25 and abs(entity.z - (z + 0.5)) <= 0.25
      assert entity.y >= y + 1.125 and entity.y <= y + 1.625
      assert {_, 0.2, _} = entity.velocity

      set(owner, %{{x + 1, y - 1, z} => @air})
      {:ok, _} = Region.step(owner, 1)
      settle(owner)
      assert blocks(owner, [side]) == [@air]

      assert Enum.sort(items(owner)) ==
               Enum.sort([{ItemTypes.id("poppy"), 1}, {ItemTypes.id("torch"), 1}])
    end

    test "breaks and their drops persist across an owner restart",
         %{owner: owner, key: key, base: dir, origin: {x, y, z} = soil} do
      flower = {x, y + 1, z}
      set(owner, %{soil => @dirt, flower => @poppy})
      set(owner, %{soil => @air})
      {:ok, _} = Region.step(owner, 1)
      settle(owner)

      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, key),
          do: TestScope.kill(pid)

      {:ok, owner} = World.owner(key)
      assert blocks(owner, [soil, flower]) == [@air, @air]
      assert items(owner) == [{ItemTypes.id("poppy"), 1}]
      assert File.dir?(dir)
    end
  end
end
