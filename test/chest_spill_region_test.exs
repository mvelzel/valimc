defmodule Valimc.ChestSpillRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{Containers, ItemLedger, Items, MiningTransfers, Region}

  setup context do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-chest-spill-#{nonce}")
    key = {82_000 + rem(nonce, 3_333) * 3, 1990}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span + 40, 64, rz * span + 40}
    source = <<nonce::128>>
    {:ok, chest} = Valimc.Physics.ChestPlacement.single_state(0.0, 89)

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
    typed = %{source => %{sequence: 8, digest: <<2::256>>}}
    containers = %{containers | receipts: typed}
    {:ok, bytes} = Containers.encode(key, containers)
    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :containers, bytes)
    Valimc.TestDisk.write(base, key, :blocks, %{position => chest})

    initial =
      if context[:capacity] do
        {x, y, z} = position

        for n <- 1..255,
            do: %{
              uuid: <<n::128>>,
              x: x + 3.5,
              y: y + 0.5,
              z: z + 0.5,
              stack: ItemStack.new("stone")
            }
      else
        []
      end

    {:ok, bytes} = ItemLedger.encode(key, initial, %{}, %ItemLedger{})
    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, {pid, _} = owner} = World.item_owner(key)
    {:ok, permit} = Region.reserve_mining(owner, [position])
    {x, y, z} = position

    self_loot = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: y + 0.5,
      z: z + 0.5,
      stack: ItemStack.new("chest")
    }

    transfer = Map.merge(permit, %{source: source, sequence: 1, records: [self_loot]})

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    %{
      base: base,
      key: key,
      position: position,
      pid: pid,
      owner: owner,
      source: source,
      chest: chest,
      containers: containers,
      stock: stock,
      typed: typed,
      initial: initial,
      transfer: transfer
    }
  end

  defp quantities(stacks) do
    Enum.reduce(stacks, %{}, fn stack, counts ->
      Map.update(counts, ItemStack.identity_key(stack), stack.count, &(&1 + stack.count))
    end)
  end

  defp audit(c, self_loot) do
    {:ok, containers} = Containers.decode(Valimc.TestDisk.read(c.base, c.key, :containers), c.key)

    assert containers.entries == %{} and containers.sequence == 3 and
             containers.receipts == c.typed

    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, c.key, :items), c.key)
    expected = if self_loot, do: [ItemStack.new("chest") | c.stock], else: c.stock
    assert quantities(Enum.map(saved.records, & &1.stack)) == quantities(expected)
    assert World.get_block(c.position) == 89
    saved
  end

  defp writing(pid, _budget \\ nil),
    do:
      Valimc.TestWait.until(fn ->
        Valimc.TestRegion.in_flight(Valimc.TestConn.state(pid).resource)
      end)

  test "survival self loot and region-owned component stacks publish together, then replay once",
       c do
    writer = :sys.get_state(c.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_mining_transfer(c.owner, c.transfer) end)

    try do
      pending = writing(c.pid)
      assert pending.containers.entries == %{}

      assert quantities(Enum.map(Items.records(pending.items), & &1.stack)) ==
               quantities([ItemStack.new("chest") | c.stock])

      # Adopted in owner memory; the published block and items wait for durability.
      assert Valimc.TestRegion.published_block(c.owner, c.position) == c.chest and
               World.item_snapshot(c.key) == %{}

      assert Task.yield(task, 10) == nil
      :sys.resume(writer)
      assert {:ok, :applied} = Task.await(task, 60_000)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end

    saved = audit(c, true)
    assert saved.receipts[c.source].sequence == 1

    assert {:ok, :applied} =
             MiningTransfers.receipt_result(c.key, c.transfer, saved.receipts[c.source])

    assert {:ok, :already_applied} = Region.apply_mining_transfer(c.owner, c.transfer)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, c.pid)
    {:ok, owner} = World.item_owner(c.key)
    assert {:ok, :already_applied} = Region.apply_mining_transfer(owner, c.transfer)
    assert audit(c, true) == saved
  end

  @tag capacity: true
  test "insufficient item admission durably refuses the entire filled mining operation", c do
    assert {:error, :item_count_limit} = World.remove_block(c.position)
    assert World.get_block(c.position) == c.chest
    assert :sys.get_state(c.pid).resource.containers == c.containers
    assert {:ok, :rejected} = Region.apply_mining_transfer(c.owner, c.transfer)
    assert World.get_block(c.position) == c.chest
    assert :sys.get_state(c.pid).resource.containers == c.containers
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, c.key, :items), c.key)
    assert saved.records == c.initial

    assert {:ok, :rejected} =
             MiningTransfers.receipt_result(c.key, c.transfer, saved.receipts[c.source])

    assert {:ok, :already_rejected} = Region.apply_mining_transfer(c.owner, c.transfer)
  end
end
