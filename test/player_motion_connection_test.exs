defmodule Valimc.PlayerMotionConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, Inventory, Players, PlayerSnapshot, PlayerStore}
  alias Valimc.Protocol.{Data, ItemStack, PackedVelocity, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-motion-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {42_000 + rem(nonce, 3_333) * 3, 750}
    names = for suffix <- ["A", "B"], do: "Move#{nonce}#{suffix}"
    {rx, rz} = key
    pos = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    for {name, index} <- Enum.with_index(names) do
      uuid = Connection.offline_uuid(name)
      snapshot = PlayerSnapshot.capture(%{pos | x: pos.x + index * 256}, Inventory.new())
      {:ok, bytes} = PlayerSnapshot.encode(uuid, snapshot)
      path = PlayerStore.path(base, uuid)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    on_exit(fn ->
      for p <- Players.all(),
          p.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for name <- names,
          {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (rx - 1)..(rx + 3),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Valimc.TestWorld.registered({x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{names: names, key: key, pos: pos}
  end

  defp login(name) do
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    pid = owner(name)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    {client, pid}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp owner(name) do
    wait(fn ->
      case Enum.find(Players.all(), &(&1.name == name)) do
        nil -> nil
        player -> player.pid
      end
    end)
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp move(client, p, flags \\ 1) do
    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<p.x::float-64, p.y::float-64, p.z::float-64, flags>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])
  end

  test "movement speed budget includes current server velocity, then rejects a forged large move",
       ctx do
    {client, pid} = login(hd(ctx.names))
    top = %{ctx.pos | y: 68.0}
    client = Client.teleport(client, pid, top)
    assert :ok = Connection.set_velocity(pid, {12.0, 0.0, 0.0})
    moved = %{top | x: top.x + 12.0}
    move(client, moved, 0)

    wait(fn ->
      current = state(pid)

      refute current.teleport_pending,
             inspect({current.player.motion, Valimc.Metrics.snapshot()})

      current.player.x == moved.x
    end)

    refute state(pid).teleport_pending
    move(client, %{top | x: top.x + 35.0}, 0)
    _client = correction(client, pid, moved)
    assert state(pid).player.x == moved.x
  end

  test "expired or out-of-bound velocity calls cannot replace velocity", ctx do
    {_client, pid} = login(hd(ctx.names))
    assert :ok = Connection.set_velocity(pid, {0.2, 0.5, 0.0})

    assert {:error, :invalid_or_expired_velocity} =
             Connection.set_velocity(pid, {65.0, 0.0, 0.0})

    # Finite values must also fit the player's bounded query.
    assert {:error, :invalid_or_expired_velocity} =
             Connection.set_velocity(pid, {64.0, 0.0, 0.0})

    assert {:error, :invalid_or_expired_velocity} =
             GenServer.call(
               pid,
               {:set_velocity, {1.0, 1.0, 1.0}, System.monotonic_time(:millisecond) - 1}
             )

    {x, _, _} = state(pid).player.motion.velocity
    assert x <= 0.2
    assert Process.alive?(pid)
  end

  test "disconnect commits the live impulse before reconnect restores it", ctx do
    name = hd(ctx.names)
    {uuid, client} = Client.login(name)
    pid = owner(name)
    # An unloaded client has not started simulation; socket exit still saves its impulse.
    assert :ok = Connection.set_velocity(pid, {0.25, 0.75, -0.5})
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == []
    end)

    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(Valimc.config(:world_path), uuid)), uuid)

    assert saved.velocity == {0.25, 0.75, -0.5}
    {^uuid, second} = Client.login(name)
    on_exit(fn -> Client.close(second) end)
    {body, _} = Client.await(second, :play, "set_entity_motion")
    {_entity, payload} = Wire.take_varint(body)
    assert {:ok, {x, y, z}} = PackedVelocity.decode(payload)
    assert abs(x - 0.25) < 0.0001 and abs(y - 0.75) < 0.0001 and abs(z + 0.5) < 0.0001
  end

  defp correction(client, pid, expected) do
    {body, client} = Client.await(client, :play, "player_position")
    assert state(pid).teleport_pending
    assert Map.take(state(pid).player, [:x, :y, :z]) == Map.take(expected, [:x, :y, :z])
    client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)
    client
  end

  test "normal ordered bursts commit requested positions and preserve later rotation", ctx do
    {client, pid} = login(hd(ctx.names))
    for n <- 1..20, do: move(client, %{ctx.pos | x: ctx.pos.x + n * 0.015})
    Client.send_packet(client, :play, "move_player_rot", <<71.0::float-32, 12.0::float-32, 1>>)
    wait(fn -> state(pid).player.x == ctx.pos.x + 0.3 end)
    assert state(pid).player.yaw == 71.0 and state(pid).player.pitch == 12.0
    refute state(pid).teleport_pending
  end

  test "an item drop following movement uses the accepted position", ctx do
    {client, pid} = login(hd(ctx.names))

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::signed-16>>,
      ItemStack.encode(ItemStack.new("stone", 1))
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    {:ok, owner} = Valimc.TestWorld.existing_owner(ctx.key)
    move(client, %{ctx.pos | x: ctx.pos.x + 0.2})

    Client.send_packet(client, :play, "player_action", [
      <<4>>,
      Wire.position({0, 0, 0}),
      <<0, 0>>
    ])

    wait(fn ->
      state(pid).player.x == ctx.pos.x + 0.2 and state(pid).inventory.slots[36] == nil and
        state(pid).recovery == nil
    end)

    [record] = Valimc.World.Entities.records(Valimc.TestRegion.section(owner).entities.store)
    assert record.x == ctx.pos.x + 0.2 and record.z == ctx.pos.z
    uuid = state(pid).player.uuid

    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(Valimc.config(:world_path), uuid)), uuid)

    assert saved.transfer_sequence == 1 and saved.outbox == nil
  end

  test "creative wall entry and impossible deltas correct to the last accepted position", ctx do
    {client, pid} = login(hd(ctx.names))
    wall = {floor(ctx.pos.x) + 1, 64, floor(ctx.pos.z)}
    :ok = Valimc.TestBlocks.set(wall, 1)
    move(client, %{ctx.pos | x: ctx.pos.x + 0.5})
    client = correction(client, pid, ctx.pos)
    move(client, %{ctx.pos | x: ctx.pos.x + 100})
    client = correction(client, pid, ctx.pos)
    move(client, %{ctx.pos | z: ctx.pos.z - 0.2})
    wait(fn -> state(pid).player.z == ctx.pos.z - 0.2 end)
    refute state(pid).teleport_pending
  end

  test "server relocation fences unacknowledged input", ctx do
    {client, pid} = login(hd(ctx.names))
    destination = %{ctx.pos | x: ctx.pos.x + 0.3}
    :ok = Connection.teleport(pid, destination)
    move(client, %{ctx.pos | x: ctx.pos.x + 1})
    client = correction(client, pid, destination)
    move(client, %{ctx.pos | x: ctx.pos.x + 0.4})
    wait(fn -> state(pid).player.x == ctx.pos.x + 0.4 end)

    assert {:error, :invalid_or_expired_teleport} =
             Connection.teleport(pid, Map.put(destination, :extra, 1))
  end
end
