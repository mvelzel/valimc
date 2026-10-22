defmodule Valimc.DeathStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.Living.{Freezing, Health}
  alias Valimc.TestScope
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore}
  alias Valimc.Protocol.ItemStack

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

      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{base: base, key: key, uuid: uuid, writer: writer, fence: fence}
  end

  defp snapshot(ctx, inventory) do
    {rx, rz} = ctx.key

    player = %{
      living: %Valimc.Living{freezing: %Freezing{}, health: %Health{value: 0.0}},
      x: rx * 128 + 0.5,
      y: 64.0,
      z: rz * 128 + 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      motion: %Valimc.PlayerMotion{},
      last_death: nil
    }

    PlayerSnapshot.capture(player, inventory)
  end

  defp saved(ctx),
    do: PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

  defp destination(ctx) do
    %{records: records} = Valimc.TestDisk.read(ctx.base, ctx.key, :items)

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
    items = Valimc.TestWorld.item_snapshot(ctx.key)
    assert map_size(items) == 44
    records = destination(ctx)
    assert Enum.count(records, &(&1.stack == ItemStack.new("stone", 7))) == 43
    assert Enum.count(records, &(&1.stack == ItemStack.new("egg", 2))) == 1
  end
end
