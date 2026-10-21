defmodule Valimc.DeathStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, PlayerTransfers, World}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-death-#{nonce}")
    key = {50_000 + rem(nonce, 3_333) * 3, 850}
    uuid = :crypto.strong_rand_bytes(16)
    TestScope.isolate([key, uuid], world_path: base)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: TestScope.kill(pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{base: base, key: key, uuid: uuid, writer: writer, fence: fence}
  end

  defp snapshot(ctx, inventory) do
    {rx, rz} = ctx.key

    player = %{
      x: rx * 128 + 0.5,
      y: 64.0,
      z: rz * 128 + 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      motion: %Valimc.PlayerMotion{},
      environment: %Valimc.PlayerEnvironment{},
      health: %Valimc.PlayerHealth{value: 0.0}
    }

    PlayerSnapshot.capture(player, inventory)
  end

  defp saved(ctx),
    do: PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

  defp destination(ctx) do
    {:ok, %{records: records}} =
      Valimc.World.ItemRecords.decode(
        Valimc.TestDisk.read(ctx.base, ctx.key, :items),
        ctx.key
      )

    records
  end

  test "disconnected death drains all inventory/cursor/grid through bounded durable batches",
       ctx do
    inventory = %Inventory{
      slots: Map.new(1..45, &{&1, ItemStack.new("stone", 7)}),
      carried: ItemStack.new("egg", 2)
    }

    cursed = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:enchantments" => %{"minecraft:vanishing_curse" => 0}}
    }

    inventory = %{inventory | slots: Map.merge(inventory.slots, %{5 => cursed, 36 => cursed})}
    monitor = Process.monitor(ctx.writer)
    assert :ok = PlayerStore.close_session(ctx.writer, ctx.fence, snapshot(ctx, inventory))
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert {:ok, stored} = saved(ctx)

    assert stored.health.value == 0 and stored.inventory.slots == %{} and
             stored.inventory.carried == nil

    assert stored.outbox == nil and stored.transfer_sequence == 9
    items = World.item_snapshot(ctx.key)
    assert map_size(items) == 44
    records = destination(ctx)
    assert Enum.count(records, &(&1.stack == ItemStack.new("stone", 7))) == 43
    assert Enum.count(records, &(&1.stack == ItemStack.new("egg", 2))) == 1
  end

  test "lost death source and already removed destination recover once before later batches",
       ctx do
    before =
      snapshot(ctx, %Inventory{slots: Map.new(36..42, &{&1, ItemStack.new("stone", &1 - 35)})})

    {:ok, after_snapshot, key, records} = PlayerTransfers.plan_death(before)
    ref = make_ref()
    PlayerStore.prepare_death(ctx.writer, ctx.fence, before, after_snapshot, key, records, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _fence, pending}}
    {:ok, _, request, _} = PlayerSnapshot.transfer_request(ctx.uuid, pending)
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :applied} = Region.apply_item_transfer(owner, request)
    removed = Enum.at(records, 1)
    {:ok, handle} = Region.find_item(owner, removed.uuid)
    assert :ok = Region.remove_item(handle)
    monitor = Process.monitor(ctx.writer)
    Process.exit(ctx.writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    {:ok, writer, recovered, fence} = PlayerStore.open(ctx.uuid)
    assert recovered.health.value == 0 and length(recovered.outbox.records) == 5
    monitor = Process.monitor(writer)
    assert :ok = PlayerStore.close_session(writer, fence, recovered)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert {:ok, stored} = saved(ctx)
    assert stored.health.value == 0 and stored.inventory.slots == %{}
    assert stored.outbox == nil and stored.transfer_sequence == 2
    items = World.item_snapshot(ctx.key)
    assert map_size(items) == 6
    refute Enum.any?(items, fn {_, item} -> item.uuid == removed.uuid end)

    assert Enum.reduce(destination(ctx), 0, fn item, sum -> sum + item.stack.count end) ==
             28 - removed.stack.count

    assert {:error, :stale_transfer} = Region.apply_item_transfer(owner, request)
  end
end
