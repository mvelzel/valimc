defmodule Valimc.KeyboardDropTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players}
  alias Valimc.World.Entities
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-keyboard-drop-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {20_000 + rem(nonce, 3_333) * 3, 400}
    name = "Drop" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    stone = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:enchantment_glint_override" => true},
        removed: MapSet.new(["minecraft:rarity"])
    }

    inventory = %Inventory{selected: 7, slots: %{43 => stone, 45 => ItemStack.new("egg", 3)}}
    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(pose, inventory))
    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn ->
      # Closing cursor delivery outlives its socket; stop it before deleting its world.
      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, name: name, uuid: uuid, pose: pose, stone: stone, path: path}
  end

  defp login(ctx) do
    {uuid, client} = Client.login(ctx.name)
    assert uuid == ctx.uuid
    Client.load_world(client)
  end

  defp await_state(ctx, predicate, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      player = Enum.find(Players.all(), &(&1.name == ctx.name))
      state = if player, do: :sys.get_state(player.pid)
      if state && predicate.(state), do: {player.pid, state}
    end)
  end

  defp departed(ctx, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      not Enum.any?(Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid), fn {_, v} ->
        v != :closing
      end) and not Enum.any?(:ets.tab2list(Players), fn {_, p} -> p.name == ctx.name end)
    end)
  end

  defp action(client, action) do
    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id(action)),
      Wire.position({0, 0, 0}),
      <<0, 0>>
    ])
  end

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    client
  end

  defp saved(ctx) do
    {:ok, snapshot} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp records(ctx) do
    {:ok, {pid, _}} = Valimc.TestWorld.item_owner(ctx.key)
    Entities.records(Valimc.TestRegion.section(pid).entities.store)
  end

  defp completed(ctx, sequence) do
    await_state(ctx, fn state ->
      snapshot = saved(ctx)
      state.recovery == nil && snapshot.transfer_sequence == sequence && snapshot.outbox == nil
    end)
  end

  test "single/all/empty drops preserve counts, patches and UUIDs through reconnect and owner reload",
       ctx do
    client = login(ctx)
    action(client, "drop_item")
    {_, state} = completed(ctx, 1)
    assert state.inventory.slots[43] == %{ctx.stone | count: 6}
    assert state.inventory.slots[45] == ItemStack.new("egg", 3)
    [one] = records(ctx)
    assert one.stack == %{ctx.stone | count: 1}
    assert one.motion.pickup_delay == 40 and not one.motion.no_gravity
    assert elem(one.motion.velocity, 2) >= 0.28
    assert one.x == ctx.pose.x and one.z == ctx.pose.z
    assert_in_delta one.y, ctx.pose.y + 1.3199999928474426, 1.0e-12
    action(client, "drop_all_items")
    {_, state} = completed(ctx, 2)
    assert state.inventory.slots[43] == nil
    original = records(ctx) |> Enum.sort_by(& &1.uuid)
    assert Enum.sort(Enum.map(original, & &1.stack.count)) == [1, 6]
    action(client, "drop_item")
    client = barrier(client)
    assert saved(ctx).transfer_sequence == 2 and length(records(ctx)) == 2
    Client.close(client)
    departed(ctx)
    {:ok, {pid, _}} = Valimc.TestWorld.item_owner(ctx.key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    second = login(ctx)
    assert second.inventory.items == Inventory.contents(state.inventory)
    assert Enum.sort_by(records(ctx), & &1.uuid) == original
    Client.close(second)
    departed(ctx)
  end
end
