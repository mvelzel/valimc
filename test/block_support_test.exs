defmodule Valimc.BlockSupportTest do
  use ExUnit.Case, async: true
  alias Valimc.Block.Support
  alias Valimc.Protocol.ItemTypes
  alias Valimc.Registry.Blocks
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  @air Blocks.default_state("air")
  @stone Blocks.default_state("stone")
  @dirt Blocks.default_state("dirt")
  @grass Blocks.default_state("grass_block")
  @sand Blocks.default_state("sand")
  @water Blocks.default_state("water")
  @short_grass Blocks.default_state("short_grass")
  @poppy Blocks.default_state("poppy")
  @torch Blocks.default_state("torch")
  @cane Blocks.default_state("sugar_cane")
  @lower Blocks.state("tall_grass", %{"half" => "lower"})
  @upper Blocks.state("tall_grass", %{"half" => "upper"})

  # Directions in vanilla order: down, up, north, south, west, east.
  @down 0
  @up 1
  @north 2
  @south 3
  @at {0, 64, 0}
  @below {0, 63, 0}
  @above {0, 65, 0}

  defp world(blocks), do: &Map.get(blocks, &1, @air)

  test "plants need soil below and break on an update from any side once unsupported" do
    for soil <- [@grass, @dirt] do
      assert Support.survives?(@at, @short_grass, world(%{@below => soil}))
      assert Support.update(@at, @short_grass, [@down], world(%{@below => soil})) == :keep
    end

    refute Support.survives?(@at, @short_grass, world(%{@below => @stone}))
    assert Support.update(@at, @short_grass, [@down], world(%{})) == :break
    assert Support.update(@at, @short_grass, [@north], world(%{@below => @sand})) == :break
    refute Support.dependent?(@stone)
    assert Support.update(@at, @stone, [@down], world(%{})) == :keep
  end

  test "a torch checks only the face it stands on" do
    assert Support.survives?(@at, @torch, world(%{@below => @stone}))
    assert Support.update(@at, @torch, [@down], world(%{})) == :break
    assert Support.update(@at, @torch, [@up, @north], world(%{})) == :keep

    wall = Blocks.state("wall_torch", %{"facing" => "north"})
    behind = {0, 64, 1}
    assert Support.survives?(@at, wall, world(%{behind => @stone}))
    refute Support.survives?(@at, wall, world(%{@below => @stone}))
    assert Support.update(@at, wall, [@south], world(%{})) == :break
    assert Support.update(@at, wall, [@down], world(%{})) == :keep
  end

  test "sugar cane needs cane below, or sand beside water, and breaks on its tick" do
    beside = {1, 63, 0}
    assert Support.survives?(@at, @cane, world(%{@below => @sand, beside => @water}))
    assert Support.survives?(@at, @cane, world(%{@below => @cane}))
    refute Support.survives?(@at, @cane, world(%{@below => @sand}))
    assert Support.update(@at, @cane, [@down], world(%{@below => @sand})) == {:tick, 1}
    assert Support.breaks?(@at, @cane, world(%{@below => @sand}))
    refute Support.breaks?(@at, @cane, world(%{@below => @cane}))
  end

  test "tall plants break when they lose their other half" do
    whole = %{@below => @grass, @above => @upper}
    assert Support.update(@at, @lower, [@up], world(whole)) == :keep
    assert Support.update(@at, @lower, [@up], world(%{@below => @grass})) == :break
    assert Support.breaks?(@at, @lower, world(%{@below => @grass}))
    assert Support.update(@above, @upper, [@down], world(%{@at => @lower})) == :keep
    assert Support.update(@above, @upper, [@down], world(%{})) == :break
  end

  test "a neighbour outside the readable region never breaks a block" do
    unknown = fn _ -> nil end
    assert Support.survives?(@at, @short_grass, unknown)
    assert Support.update(@at, @lower, [@up, @down], unknown) == :keep
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

    test "a sugar cane column falls one block per tick and a tall plant loses both halves",
         %{owner: owner, origin: {x, y, z} = base} do
      cane = for dy <- 1..3, do: {x, y + dy, z}
      grass = {x + 4, y, z}
      tall = [{x + 4, y + 1, z}, {x + 4, y + 2, z}]

      set(
        owner,
        Map.merge(
          %{base => @sand, {x + 1, y, z} => @water, grass => @grass},
          Map.new(Enum.zip(tall, [@lower, @upper]) ++ Enum.map(cane, &{&1, @cane}))
        )
      )

      # Removing the water leaves the cane standing: it watches only its own neighbours.
      set(owner, %{{x + 1, y, z} => @stone})
      {:ok, _} = Region.step(owner, 1)
      assert blocks(owner, cane) == [@cane, @cane, @cane]
      set(owner, %{base => @air})
      {:ok, _} = Region.step(owner, 1)
      assert blocks(owner, cane) == [@air, @cane, @cane]
      {:ok, _} = Region.step(owner, 2)
      assert blocks(owner, cane) == [@air, @air, @air]

      set(owner, %{List.last(tall) => @air})
      {:ok, _} = Region.step(owner, 1)
      assert blocks(owner, tall) == [@air, @air]
      settle(owner)
      # Tall grass drops only by chance or to shears; that loot is not evaluated yet.
      assert items(owner) == List.duplicate({ItemTypes.id("sugar_cane"), 1}, 3)
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
