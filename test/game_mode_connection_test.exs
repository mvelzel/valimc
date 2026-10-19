defmodule Valimc.GameModeConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{GameMode, Inventory, Players, PlayerAbilities, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mode-#{nonce}")
    old = Valimc.config(:world_path)
    old_mode = Valimc.config(:default_game_mode)
    Application.put_env(:valimc, :world_path, base)
    name = "Mode" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    key = {90_000 + rem(nonce, 10_000), 500}
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    inventory = %Inventory{
      slots: %{36 => ItemStack.new("stone", 7), 45 => ItemStack.new("egg", 3)}
    }

    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))

    on_exit(fn ->
      for {pid, p} <- :ets.tab2list(Players),
          p.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Application.put_env(:valimc, :default_game_mode, old_mode)
      File.rm_rf!(base)
    end)

    %{base: base, name: name, uuid: uuid, path: path, pose: pose, inventory: inventory, key: key}
  end

  defp seed(ctx, mode, flying \\ true) do
    player = Map.merge(ctx.pose, %{game_mode: mode, abilities: %PlayerAbilities{flying: flying}})
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, ctx.inventory))
    File.write!(ctx.path, bytes)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    Client.load_world(client)
  end

  defp state(ctx), do: :sys.get_state(Enum.find(Players.all(), &(&1.name == ctx.name)).pid)

  defp wait(fun, attempts \\ 500) do
    if fun.(),
      do: :ok,
      else:
        (
          assert attempts > 0
          Process.sleep(5)
          wait(fun, attempts - 1)
        )
  end

  defp close(ctx, client) do
    ref = Process.monitor(state(ctx).player.pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 6000
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
  end

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await(client, :play, "system_chat")
    client
  end

  defp action(client, action, pos) do
    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id(action)),
      Wire.position(pos),
      <<1>>,
      Wire.varint(0)
    ])
  end

  defp click(client, type, slot, button) do
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, slot::signed-16, button>>,
      Wire.varint(ItemTypes.input_id(type)),
      <<0, 0>>
    ])

    barrier(client)
  end

  test "every saved mode controls initialization, overrides the default and survives reconnect",
       ctx do
    for mode <- [:survival, :creative, :adventure, :spectator] do
      saved_mode = %GameMode{current: mode, previous: :adventure}
      seed(ctx, saved_mode)
      Application.put_env(:valimc, :default_game_mode, :survival)
      client = login(ctx)
      s = state(ctx)
      assert s.player.game_mode == saved_mode
      assert s.player.abilities == GameMode.abilities(saved_mode, true)
      assert client.abilities.flags == PlayerAbilities.flags(s.player.abilities)

      for {id, base, modifiers} <- Valimc.PlayerInteraction.attributes(mode) do
        assert client.attributes[{s.player.entity_id, id}] == {base, modifiers}
      end

      assert client.attributes[{s.player.entity_id, 1}] == {0.0, []}
      assert client.attributes[{s.player.entity_id, 2}] == {0.0, []}
      assert client.attributes[{s.player.entity_id, 10}] == {1.0, []}

      assert s.inventory.infinite_materials == (mode == :creative)
      assert client.inventory.items == Inventory.contents(ctx.inventory)
      close(ctx, client)
      Application.put_env(:valimc, :default_game_mode, :creative)
      second = login(ctx)
      assert state(ctx).player.game_mode == saved_mode
      assert second.inventory.items == client.inventory.items
      close(ctx, second)
    end
  end

  test "absent mode uses the configured default while flight/permission is rederived", ctx do
    old =
      PlayerSnapshot.capture(
        Map.put(ctx.pose, :abilities, %PlayerAbilities{flying: true}),
        ctx.inventory
      )

    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, old)
    File.write!(ctx.path, bytes)
    Application.put_env(:valimc, :default_game_mode, :survival)
    client = login(ctx)
    assert state(ctx).player.game_mode == GameMode.new(:survival)
    assert client.abilities.flags == 0 and not state(ctx).inventory.infinite_materials
    close(ctx, client)
    {:ok, current} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert current.game_mode == GameMode.new(:survival) and not current.flying
    File.rm!(ctx.path)
    Application.put_env(:valimc, :default_game_mode, :spectator)
    fresh = login(ctx)
    assert state(ctx).player.game_mode == GameMode.new(:spectator)
    assert fresh.abilities.flags == 7
    close(ctx, fresh)
  end

  test "unprivileged native mode requests are parsed but never change saved mode or abilities",
       ctx do
    seed(ctx, GameMode.new(:creative), false)
    client = login(ctx)
    initial = state(ctx)

    client =
      Enum.reduce([-1, 0, 1, 2, 3, 4, 127], client, fn mode, client ->
        Client.send_packet(client, :play, "change_game_mode", Wire.varint(mode))
        client = barrier(client)
        assert state(ctx).player.game_mode == initial.player.game_mode
        assert state(ctx).player.abilities == initial.player.abilities
        assert client.abilities.flags == 13
        client
      end)

    close(ctx, client)
  end

  test "pending journal recovery retains saved mode without granting creative permission", ctx do
    mode = %GameMode{current: :adventure, previous: :creative}
    player = Map.merge(ctx.pose, %{game_mode: mode, abilities: %PlayerAbilities{flying: false}})
    before = PlayerSnapshot.capture(player, ctx.inventory)

    after_state = %{
      before
      | inventory: %{
          before.inventory
          | slots: Map.put(before.inventory.slots, 36, ItemStack.new("stone", 6))
        }
    }

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: ctx.pose.x,
      y: 65.0,
      z: ctx.pose.z,
      stack: ItemStack.new("stone")
    }

    {:ok, pending} =
      Valimc.PlayerTransfers.prepare(ctx.uuid, 0, before, after_state, ctx.key, [record])

    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, pending)
    File.write!(ctx.path, bytes)
    client = login(ctx)
    s = state(ctx)
    assert s.player.game_mode == mode and client.abilities.flags == 0
    assert not s.inventory.infinite_materials and s.inventory.slots[36].count == 6
    assert s.recovery == nil
    saved = :sys.get_state(s.player_store).snapshot
    assert saved.game_mode == mode and saved.transfer_sequence == 1 and saved.outbox == nil
    assert map_size(World.item_snapshot(ctx.key)) == 1
    close(ctx, client)
  end

  test "malformed mode requests disconnect without altering accepted player state", ctx do
    seed(ctx, GameMode.new(:creative), false)
    client = login(ctx)
    ref = Process.monitor(state(ctx).player.pid)

    Client.send_raw(client, [
      Wire.frame(
        Valimc.Protocol.Data.id(:play, :serverbound, "player_abilities"),
        <<2>>,
        client.threshold
      ),
      Wire.frame(
        Valimc.Protocol.Data.id(:play, :serverbound, "change_game_mode"),
        <<1, 0>>,
        client.threshold
      )
    ])

    assert_receive {:DOWN, ^ref, :process, _, :normal}, 6000
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.game_mode == GameMode.new(:creative) and saved.flying
  end

  test "spectator click/drop/swap and forged creative creation leave owned contents and journal unchanged",
       ctx do
    seed(ctx, GameMode.new(:spectator))
    client = login(ctx)
    initial = state(ctx)
    client = click(client, "pickup", 36, 0)
    client = click(client, "throw", 36, 1)

    for action <- ["drop_item", "drop_all_items", "swap_item_with_offhand"],
        do: action(client, action, {0, 0, 0})

    for slot <- [-1, 36] do
      Client.send_packet(client, :play, "set_creative_mode_slot", [
        <<slot::signed-16>>,
        ItemStack.encode(ItemStack.new("diamond"), :untrusted)
      ])
    end

    client = barrier(client)
    s = state(ctx)
    assert s.inventory.slots == initial.inventory.slots and s.inventory.carried == nil
    assert s.recovery == nil and s.creative_input.queued == 0
    assert :sys.get_state(s.player_store).snapshot.transfer_sequence == 0
    assert World.item_snapshot(ctx.key) == %{}
    close(ctx, client)
  end

  test "non-creative modes cannot use instant preview breaks, free placement, clone or creative writes",
       ctx do
    {x, z} = {floor(ctx.pose.x), floor(ctx.pose.z)}
    target = {x + 1, 64, z}

    for mode <- [:survival, :adventure, :spectator] do
      seed(ctx, GameMode.new(mode), false)
      client = login(ctx)
      assert World.get_block(target) == 0

      Client.send_packet(client, :play, "use_item_on", [
        <<0>>,
        Wire.position({x + 1, 63, z}),
        <<1, 0.5::float-32, 1.0::float-32, 0.5::float-32, 0, 0, 0>>
      ])

      {<<0>>, client} = Client.await(client, :play, "block_changed_ack")
      assert World.get_block(target) == 0
      assert client.inventory.items == Inventory.contents(ctx.inventory)
      assert client.inventory.state_id > 0
      :ok = World.set_block(target, 1)
      action(client, "start_destroy_block", target)
      action(client, "stop_destroy_block", target)
      client = barrier(client)
      assert World.get_block(target) == 1
      client = click(client, "clone", 36, 2)

      Client.send_packet(client, :play, "set_creative_mode_slot", [
        <<36::signed-16>>,
        ItemStack.encode(ItemStack.new("diamond"), :untrusted)
      ])

      client = barrier(client)

      assert state(ctx).inventory.slots == ctx.inventory.slots and
               state(ctx).inventory.carried == nil

      close(ctx, client)
      :ok = World.set_block(target, 0)
    end
  end
end
