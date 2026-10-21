defmodule Valimc.BlockSupportTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemTypes
  alias Valimc.Registry.Blocks
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  # Survival and update rules are compared by the support oracle stage and run in
  # Rust (VMC-077m); these tests cover the owner's commits, drops and persistence.
  @air Blocks.default_state("air")
  @stone Blocks.default_state("stone")
  @dirt Blocks.default_state("dirt")
  @poppy Blocks.default_state("poppy")
  @torch Blocks.default_state("torch")
  @wire Blocks.default_state("redstone_wire")
  @redstone_block Blocks.default_state("redstone_block")

  describe "in a region owner" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {76_000 + rem(nonce, 3_333) * 3, 1830}
      base = Path.join(System.tmp_dir!(), "valimc-support-#{nonce}")
      TestScope.isolate(key, world_path: base, region_ticks: :manual, random_tick_speed: 0)

      on_exit(fn ->
        for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
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
      for {_, entry} <- :sys.get_state(pid).resource.entities.items.entries,
          do: {entry.stack.item_id, entry.stack.count}
    end

    # Waits until every queued commit is durable.
    defp settle({pid, _}, _budget \\ nil) do
      # A write still in flight answers busy; the flush itself must then succeed.
      Valimc.TestWait.until(fn -> Region.flush(pid) == :ok end)
      :ok
    end

    test "a flower and a torch on a removed block break at once and drop",
         %{owner: owner, origin: {x, y, z} = soil} do
      flower = {x, y + 1, z}
      torch = {x, y - 1, z}
      side = {x + 1, y, z}
      set(owner, %{soil => @dirt, flower => @poppy, torch => @torch, side => @torch})
      set(owner, %{{x, y - 2, z} => @stone, {x + 1, y - 1, z} => @stone})
      set(owner, %{soil => @air})
      settle(owner)
      # Both torches stand on stone: the removed block is above one and beside the other.
      assert blocks(owner, [flower, torch, side]) == [@air, @torch, @torch]
      assert items(owner) == [{ItemTypes.id("poppy"), 1}]

      # The drop pops near the block centre and is launched upwards, not left hovering.
      [entity] =
        for {_, entry} <- :sys.get_state(elem(owner, 0)).resource.entities.items.entries,
            do: entry.entity

      assert abs(entity.x - (x + 0.5)) <= 0.25 and abs(entity.z - (z + 0.5)) <= 0.25
      assert entity.y >= y + 1.125 and entity.y <= y + 1.625
      assert {_, 0.2, _} = entity.velocity

      set(owner, %{{x + 1, y - 1, z} => @air})
      settle(owner)
      assert blocks(owner, [side]) == [@air]

      assert Enum.sort(items(owner)) ==
               Enum.sort([{ItemTypes.id("poppy"), 1}, {ItemTypes.id("torch"), 1}])
    end

    # Wire power is compared by the redstone wire oracle stage; this covers the
    # owner committing it.
    test "wire carries a redstone block's power and pops off without its floor",
         %{owner: owner, origin: {x, y, z}} do
      [near, far] = wires = [{x + 1, y, z}, {x + 2, y, z}]
      power = fn -> for s <- blocks(owner, wires), do: Map.new(Blocks.properties(s))["power"] end
      set(owner, Map.new(-1..3, &{{x + &1, y - 1, z}, @stone}))
      set(owner, %{{x, y, z} => @redstone_block})
      set(owner, %{near => @wire})
      set(owner, %{far => @wire})
      settle(owner)
      assert power.() == ["15", "14"]

      set(owner, %{{x, y, z} => @air})
      settle(owner)
      assert power.() == ["0", "0"]

      set(owner, %{{x + 2, y - 1, z} => @air})
      settle(owner)
      assert blocks(owner, [far]) == [@air]
      assert items(owner) == [{ItemTypes.id("redstone"), 1}]
    end

    # 64 wires in one commit run past the normal scheduler's update budget; the
    # run is redone dirty.
    test "a long wire line placed at once carries power 15 down to 0",
         %{owner: owner, origin: {x, y, z}} do
      wires = for i <- 1..64, do: {x + i, y, z}
      set(owner, Map.new(0..64, &{{x + &1, y - 1, z}, @stone}))
      set(owner, Map.new(wires, &{&1, @wire}) |> Map.put({x, y, z}, @redstone_block))
      settle(owner)

      powers =
        for s <- blocks(owner, wires),
            do: String.to_integer(Map.new(Blocks.properties(s))["power"])

      assert powers == Enum.map(1..64, &max(16 - &1, 0))
    end

    test "breaks and their drops persist across an owner restart",
         %{owner: owner, key: key, base: dir, origin: {x, y, z} = soil} do
      flower = {x, y + 1, z}
      set(owner, %{soil => @dirt, flower => @poppy})
      set(owner, %{soil => @air})
      settle(owner)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      {:ok, owner} = World.owner(key)
      assert blocks(owner, [soil, flower]) == [@air, @air]
      assert items(owner) == [{ItemTypes.id("poppy"), 1}]
      assert File.dir?(dir)
    end
  end
end
