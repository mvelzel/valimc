defmodule Valimc.KeyboardDropTest do
  use ExUnit.Case, async: false
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.World.Items
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-keyboard-drop-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {20_000 + rem(nonce, 10_000), 400}
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
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, name: name, uuid: uuid, pose: pose, stone: stone, path: path}
  end

  defp login(ctx) do
    {uuid, client} = Client.login(ctx.name)
    assert uuid == ctx.uuid
    Client.load_world(client)
  end

  defp await_state(ctx, predicate, attempts \\ 1000) do
    player = Enum.find(Players.all(), &(&1.name == ctx.name))
    state = if player, do: :sys.get_state(player.pid)

    if state && predicate.(state) do
      {player.pid, state}
    else
      assert attempts > 0
      Process.sleep(2)
      await_state(ctx, predicate, attempts - 1)
    end
  end

  defp departed(ctx, attempts \\ 1000) do
    if Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) != [] or
         Enum.any?(:ets.tab2list(Players), fn {_, p} -> p.name == ctx.name end) do
      assert attempts > 0
      Process.sleep(2)
      departed(ctx, attempts - 1)
    end
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
    {_, client} = Client.await(client, :play, "system_chat")
    client
  end

  defp saved(ctx) do
    {:ok, snapshot} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp records(ctx) do
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    Items.records(:sys.get_state(pid).items)
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
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    second = login(ctx)
    assert second.inventory.items == Inventory.contents(state.inventory)
    assert Enum.sort_by(records(ctx), & &1.uuid) == original
    Client.close(second)
    departed(ctx)
  end

  test "source/destination stalls fence all inventory changes while movement and chat stay live",
       ctx do
    client = login(ctx)
    {pid, state} = await_state(ctx, &(&1.recovery == nil))
    source = state.player_store
    {:ok, {region, _}} = World.item_owner(ctx.key)
    destination = :sys.get_state(region).store
    :sys.suspend(source)
    :sys.suspend(destination)

    try do
      action(client, "drop_item")
      {^pid, before} = await_state(ctx, &(&1.recovery != nil && &1.recovery.stage == :prepare))

      Client.send_packet(client, :play, "set_creative_mode_slot", [
        <<43::signed-16>>,
        ItemStack.encode(ItemStack.new("stone", 64), :untrusted)
      ])

      Client.send_packet(client, :play, "set_carried_item", <<8::signed-16>>)
      action(client, "swap_item_with_offhand")
      action(client, "drop_all_items")

      Client.send_packet(client, :play, "container_click", [
        <<0, 0, 43::signed-16, 0>>,
        Wire.varint(ItemTypes.input_id("pickup")),
        <<0, 0>>
      ])

      Client.send_packet(client, :play, "container_close", <<0>>)
      target = {floor(ctx.pose.x), 63, floor(ctx.pose.z)}

      Client.send_packet(client, :play, "use_item_on", [
        <<0>>,
        Wire.position(target),
        <<1, 0::96, 0, 0, 1>>
      ])

      Client.send_packet(
        client,
        :play,
        "move_player_pos",
        <<ctx.pose.x + 1::float-64, 64.0::float-64, ctx.pose.z::float-64, 1>>
      )

      client = barrier(client)
      send(pid, :save_player)
      frozen = :sys.get_state(pid)
      assert client.selected == 7
      assert frozen.inventory.slots == before.inventory.slots and frozen.inventory.selected == 7
      assert frozen.inventory.carried == nil and frozen.save_ref == nil
      assert frozen.player.x == ctx.pose.x + 1
      assert World.get_block({elem(target, 0), 64, elem(target, 2)}) == 0
      assert records(ctx) == [] and saved(ctx).transfer_sequence == 0
      :sys.resume(source)

      {^pid, prepared} =
        await_state(
          ctx,
          &(&1.recovery != nil && &1.recovery.stage == :delivery &&
              :sys.get_state(region).item_pending != nil)
        )

      assert prepared.inventory.slots[43] == %{ctx.stone | count: 6}
      assert saved(ctx).outbox != nil and World.item_snapshot(ctx.key) == %{}
      action(client, "drop_all_items")
      action(client, "swap_item_with_offhand")
      Client.send_packet(client, :play, "set_carried_item", <<8::signed-16>>)
      job = prepared.recovery.job
      send(pid, {:transfer_delivered, self(), job.token, {:ok, :applied}})
      send(pid, {:player_transfer_saved, make_ref(), {:ok, make_ref(), saved(ctx)}})
      send(pid, {:recovery_deadline, make_ref()})
      client = barrier(client)
      assert :sys.get_state(pid).inventory.selected == 7
      last_id = :sys.get_state(pid).inventory.state_id
      :sys.resume(destination)
      {^pid, finished} = completed(ctx, 1)
      assert finished.inventory.state_id > last_id
      assert finished.player.x == ctx.pose.x + 1 and length(records(ctx)) == 1
      action(client, "swap_item_with_offhand")
      client = barrier(client)
      assert :sys.get_state(pid).inventory.slots[43] == ItemStack.new("egg", 3)
      assert :sys.get_state(pid).inventory.slots[45] == %{ctx.stone | count: 6}
      Client.close(client)
    after
      if Process.alive?(source), do: :sys.resume(source)
      if Process.alive?(destination), do: :sys.resume(destination)
      Client.close(client)
      departed(ctx)
    end
  end

  test "disconnect or deadline after prepare recovers a possibly committed delivery exactly once",
       ctx do
    for failure <- [:disconnect, :deadline] do
      client = login(ctx)
      {pid, _} = await_state(ctx, &(&1.recovery == nil))
      {:ok, {region, _}} = World.item_owner(ctx.key)
      destination = :sys.get_state(region).store
      :sys.suspend(destination)
      action(client, "drop_item")

      {^pid, pending} =
        await_state(
          ctx,
          &(&1.recovery != nil && &1.recovery.stage == :delivery &&
              :sys.get_state(region).item_pending != nil)
        )

      sequence = pending.recovery.intent.transfer_sequence
      if failure == :deadline, do: send(pid, {:recovery_deadline, pending.recovery.id})
      Client.close(client)
      departed(ctx)
      :sys.resume(destination)
      second = login(ctx)
      {_, state} = completed(ctx, sequence)
      assert state.inventory.slots[43] == %{ctx.stone | count: 7 - sequence}
      assert length(records(ctx)) == sequence
      Client.close(second)
      departed(ctx)
    end
  end

  test "an outstanding periodic save rejects a drop without queuing a source plan", ctx do
    client = login(ctx)
    {pid, state} = await_state(ctx, &(&1.recovery == nil))
    :sys.suspend(state.player_store)

    try do
      send(pid, :save_player)
      {^pid, saving} = await_state(ctx, &(&1.save_ref != nil))
      action(client, "drop_item")
      client = barrier(client)
      frozen = :sys.get_state(pid)
      assert frozen.recovery == nil and frozen.save_ref == saving.save_ref
      assert frozen.inventory.slots[43] == ctx.stone and records(ctx) == []
      :sys.resume(state.player_store)
      await_state(ctx, &(&1.save_ref == nil))
      action(client, "drop_item")
      completed(ctx, 1)
      Client.close(client)
    after
      if Process.alive?(state.player_store), do: :sys.resume(state.player_store)
      Client.close(client)
      departed(ctx)
    end
  end

  test "a source write failure never publishes a destination and preserves the previous file",
       ctx do
    client = login(ctx)
    original = File.read!(ctx.path)
    {_, state} = await_state(ctx, &(&1.recovery == nil))

    :sys.replace_state(state.player_store, fn s ->
      %{s | path: Path.join(ctx.base, "blocked/player.pose")}
    end)

    File.write!(Path.join(ctx.base, "blocked"), "not a directory")

    capture_log(fn ->
      action(client, "drop_item")
      {_, _} = Client.await(client, :play, "disconnect")
      departed(ctx)
    end)

    assert records(ctx) == [] and File.read!(ctx.path) == original
    Client.close(client)
  end

  test "storage-disabled source corrects inventory and allows the session to continue", ctx do
    client = login(ctx)
    {_, state} = await_state(ctx, &(&1.recovery == nil))
    :sys.replace_state(state.player_store, &%{&1 | path: nil})
    action(client, "drop_item")
    {_, client} = Client.await(client, :play, "system_chat")
    client = barrier(client)
    {_, state} = await_state(ctx, &(&1.recovery == nil))
    assert state.inventory.slots[43] == ctx.stone and records(ctx) == []
    Client.close(client)
    departed(ctx)
  end
end
