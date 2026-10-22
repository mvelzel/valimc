defmodule Valimc.FlightConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, Players, PlayerAbilities, PlayerStore}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-flight-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 3_333) * 3, 500}
    name = "Flight" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 70.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}, selected: 0}
    path = PlayerStore.path(base, uuid)
    {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(pose, inventory))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn ->
      for {pid, player} <- :ets.tab2list(Players),
          player.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{name: name, uuid: uuid, path: path, key: key}
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    Client.load_world(client)
  end

  defp state(ctx), do: Valimc.TestConn.state(Enum.find(Players.all(), &(&1.name == ctx.name)).pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp saved(ctx) do
    {:ok, snapshot} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp departed(ctx),
    do: wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)

  defp close(ctx, client) do
    ref = Process.monitor(state(ctx).player.pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    departed(ctx)
  end

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    client
  end

  defp toggle(client, flags), do: Client.send_packet(client, :play, "player_abilities", <<flags>>)

  defp drop(client) do
    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id("drop_item")),
      Wire.position({0, 0, 0}),
      <<0>>,
      Wire.varint(0)
    ])
  end

  test "accepted flight persists with inventory and reconnect advertises it without request echoes",
       ctx do
    client = login(ctx)
    assert client.abilities.flags == 13
    initial = state(ctx)
    client = toggle(client, 255) |> barrier()
    s = state(ctx)
    assert s.player.abilities.flying and s.inventory == initial.inventory
    assert s.player.abilities == %{initial.player.abilities | flying: true}
    assert client.abilities.flags == 13
    close(ctx, client)
    assert saved(ctx).flying
    second = login(ctx)
    assert second.abilities.flags == 15
    assert second.inventory.items == client.inventory.items and second.selected == client.selected
    second = toggle(second, 253) |> barrier()
    refute state(ctx).player.abilities.flying
    assert second.abilities.flags == 15
    close(ctx, second)
    third = login(ctx)
    assert third.abilities.flags == 13
    close(ctx, third)
  end

  test "forged flags cannot grant denied abilities; a later malformed frame preserves accepted flight",
       ctx do
    client = login(ctx)
    pid = state(ctx).player.pid

    Valimc.TestConn.replace(pid, fn s ->
      %{s | player: %{s.player | abilities: PlayerAbilities.for_mode(:survival)}}
    end)

    client = toggle(client, 255) |> barrier()
    assert state(ctx).player.abilities == PlayerAbilities.for_mode(:survival)

    Valimc.TestConn.replace(pid, fn s ->
      %{s | player: %{s.player | abilities: PlayerAbilities.for_mode(:creative)}}
    end)

    ref = Process.monitor(pid)

    Client.send_raw(client, [
      Wire.frame(Data.id(:play, :serverbound, "player_abilities"), <<2>>, client.threshold),
      Wire.frame(Data.id(:play, :serverbound, "player_abilities"), <<2, 0>>, client.threshold)
    ])

    assert_receive {:DOWN, ^ref, :process, _, :normal}
    Client.close(client)
    departed(ctx)
    assert saved(ctx).flying
    rejoined = login(ctx)
    assert rejoined.abilities.flags == 15
    close(ctx, rejoined)
  end

  test "late transfer completion cannot roll back flight accepted while the destination is stalled",
       ctx do
    client = login(ctx) |> toggle(2) |> barrier()
    {:ok, _} = Valimc.TestWorld.item_owner(ctx.key)
    writer = Valimc.TestDisk.stripe(Valimc.config(:world_path), ctx.key)
    :sys.suspend(writer)

    try do
      drop(client)

      wait(fn ->
        s = state(ctx)
        s.recovery != nil and s.recovery.stage == :delivery
      end)

      assert saved(ctx).flying and saved(ctx).outbox != nil
      client = toggle(client, 0) |> barrier()
      refute state(ctx).player.abilities.flying
      :sys.resume(writer)
      wait(fn -> state(ctx).recovery == nil end)
      refute state(ctx).player.abilities.flying
      assert state(ctx).inventory.slots[36].count == 6
      close(ctx, client)
      refute saved(ctx).flying
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      rejoined = login(ctx)

      assert rejoined.abilities.flags == 13 and
               rejoined.inventory.items |> Enum.at(36) |> Map.fetch!(:count) == 6

      close(ctx, rejoined)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "disconnect preserves newer flight while keeping a pending transfer fenced", ctx do
    client = login(ctx)
    {:ok, _} = Valimc.TestWorld.item_owner(ctx.key)
    writer = Valimc.TestDisk.stripe(Valimc.config(:world_path), ctx.key)
    :sys.suspend(writer)

    try do
      drop(client)

      wait(fn ->
        s = state(ctx)
        s.recovery != nil and s.recovery.stage == :delivery
      end)

      client = toggle(client, 2) |> barrier()
      ref = Process.monitor(state(ctx).player.pid)
      Client.close(client)
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert saved(ctx).flying and saved(ctx).outbox != nil
      assert saved(ctx).inventory.slots[36].count == 6
      :sys.resume(writer)
      departed(ctx)
      rejoined = login(ctx)
      assert rejoined.abilities.flags == 15
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      close(ctx, rejoined)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end
end
