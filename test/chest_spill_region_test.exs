defmodule Valimc.ChestSpillRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-chest-spill-#{nonce}")
    key = {82_000 + rem(nonce, 3_333) * 3, 1990}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span + 40, 64, rz * span + 40}
    {:ok, chest} = Valimc.Blocks.ChestPlacement.single_state(0.0, 89)

    named = %{
      ItemStack.new("oak_planks", 99)
      | components: %{
          "minecraft:custom_name" => {:string, "Stored"},
          "minecraft:max_stack_size" => 99
        }
    }

    damaged = %{ItemStack.new("diamond_axe") | components: %{"minecraft:damage" => 5}}
    stock = [ItemStack.new("oak_planks", 64), named, damaged]
    {:ok, containers, entry} = Containers.create(%Containers{}, key, position, 3)
    slots = entry.slots |> put_elem(0, hd(stock)) |> put_elem(1, named) |> put_elem(26, damaged)
    {:ok, containers, _} = Containers.replace(containers, position, entry.revision, slots)
    {:ok, bytes} = Containers.encode(key, containers)
    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :containers, bytes)
    Valimc.TestDisk.write(base, key, :blocks, %{position => chest})

    Valimc.TestDisk.write(base, key, :items, nil)
    {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(key)
    {x, y, z} = position

    self_loot = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: y + 0.5,
      z: z + 0.5,
      stack: ItemStack.new("chest")
    }

    on_exit(fn ->
      for {live, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    %{
      base: base,
      key: key,
      position: position,
      pid: pid,
      owner: owner,
      chest: chest,
      stock: stock,
      self_loot: self_loot
    }
  end

  defp quantities(stacks) do
    Enum.reduce(stacks, %{}, fn stack, counts ->
      Map.update(counts, ItemStack.identity_key(stack), stack.count, &(&1 + stack.count))
    end)
  end

  defp audit(c, self_loot) do
    {:ok, containers} = Containers.decode(Valimc.TestDisk.read(c.base, c.key, :containers), c.key)

    assert containers.entries == %{} and containers.sequence == 3

    saved = Valimc.TestDisk.read(c.base, c.key, :items)
    expected = if self_loot, do: [ItemStack.new("chest") | c.stock], else: c.stock
    assert quantities(Enum.map(saved.records, & &1.stack)) == quantities(expected)
    assert Valimc.TestBlocks.get(c.position) == 89
    saved
  end

  test "a survival break spills the chest's stacks with its own drop in one call; it survives a restart",
       c do
    assert :ok = Region.mine_block(c.owner, c.position, c.chest, [c.self_loot])
    assert :ok = Region.flush(c.pid)
    saved = audit(c, true)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, c.pid)
    {:ok, _owner} = Valimc.TestWorld.item_owner(c.key)
    assert audit(c, true) == saved
  end
end
