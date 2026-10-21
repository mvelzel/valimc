defmodule Valimc.PlayerMotionConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, Inventory, Players, PlayerSnapshot, PlayerStore, World}
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
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
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

  test "new impulses retire stalled geometry and expired/invalid calls cannot replace velocity",
       ctx do
    {_client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      assert :ok = Connection.set_velocity(pid, {0.4, 0.8, 0.0})
      job = wait(fn -> Valimc.TestConn.job(state(pid), :pose) end)
      assert :ok = Connection.set_velocity(pid, {0.2, 0.5, 0.0})
      refute Process.alive?(job.task.pid)

      send(
        pid,
        {job.task.ref,
         {:ok,
          %{
            pose: :standing,
            powder_snow: false,
            fences: %{},
            kinetics: %{
              velocity: {63.0, 63.0, 63.0},
              physical_ground: false,
              settled: false,
              bounced: true,
              stuck_multiplier: {0.25, 0.05000000074505806, 0.25},
              paths: %Valimc.Physics.MovementPaths{}
            }
          }}}
      )

      # The state read follows the forged reply in the connection's mailbox.
      assert state(pid).player.motion.velocity == {0.2, 0.5, 0.0}
      assert state(pid).player.motion.stuck_multiplier == {0.0, 0.0, 0.0}

      assert {:error, :invalid_or_expired_velocity} =
               Connection.set_velocity(pid, {65.0, 0.0, 0.0})

      # Finite values must also fit the existing bounded geometry plan.
      assert {:error, :invalid_or_expired_velocity} =
               Connection.set_velocity(pid, {64.0, 0.0, 0.0})

      assert {:error, :invalid_or_expired_velocity} =
               GenServer.call(
                 pid,
                 {:set_velocity, {1.0, 1.0, 1.0}, System.monotonic_time(:millisecond) - 1}
               )

      assert state(pid).player.motion.velocity == {0.2, 0.5, 0.0}
      Valimc.TestRegionGate.resume(owner)
      wait(fn -> elem(state(pid).player.motion.velocity, 1) < 0.5 end)
      assert Process.alive?(pid)
    after
      Valimc.TestRegionGate.resume(owner)
    end
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
    assert state(pid).motion_pending == nil
    assert state(pid).player.yaw == 71.0 and state(pid).player.pitch == 12.0
    refute state(pid).teleport_pending
  end

  test "an item drop following movement waits and uses the accepted position", ctx do
    {client, pid} = login(hd(ctx.names))

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<36::signed-16>>,
      ItemStack.encode(ItemStack.new("stone", 1))
    ])

    {_, client} = Client.await(client, :play, "container_set_slot")
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)

      Client.send_packet(client, :play, "player_action", [
        <<4>>,
        Wire.position({0, 0, 0}),
        <<0, 0>>
      ])

      assert state(pid).recovery == nil
      Valimc.TestRegionGate.resume(owner)

      wait(fn ->
        state(pid).player.x == ctx.pos.x + 0.2 and state(pid).inventory.slots[36] == nil and
          state(pid).recovery == nil
      end)

      [record] = Valimc.World.Items.records(:sys.get_state(owner).resource.items)
      assert record.x == ctx.pos.x + 0.2 and record.z == ctx.pos.z

      uuid = state(pid).player.uuid

      {:ok, saved} =
        PlayerSnapshot.decode(
          File.read!(PlayerStore.path(Valimc.config(:world_path), uuid)),
          uuid
        )

      assert saved.transfer_sequence == 1 and saved.outbox == nil
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "creative wall entry and impossible deltas correct to the last accepted position", ctx do
    {client, pid} = login(hd(ctx.names))
    wall = {floor(ctx.pos.x) + 1, 64, floor(ctx.pos.z)}
    :ok = World.set_block(wall, 1)
    move(client, %{ctx.pos | x: ctx.pos.x + 0.5})
    client = correction(client, pid, ctx.pos)
    move(client, %{ctx.pos | x: ctx.pos.x + 100})
    client = correction(client, pid, ctx.pos)
    move(client, %{ctx.pos | z: ctx.pos.z - 0.2})
    wait(fn -> state(pid).player.z == ctx.pos.z - 0.2 end)
    refute state(pid).teleport_pending
  end

  test "a blocked source times out only its player and recovers after acknowledgment", ctx do
    {client, pid} = login(hd(ctx.names))
    {other, independent} = login(List.last(ctx.names))
    other_pos = state(independent).player
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      job = wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      move(other, %{other_pos | x: other_pos.x + 0.2})
      wait(fn -> state(independent).player.x == other_pos.x + 0.2 end)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      client = correction(client, pid, ctx.pos)
      {_, client} = Client.await_stats(client)
      refute Process.alive?(job.task.pid)
      Valimc.TestRegionGate.resume(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.2 end)
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "server relocation cancels old work, ignores retired results, and fences unacknowledged input",
       ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      job = wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      destination = %{ctx.pos | x: ctx.pos.x + 0.3}
      :ok = Connection.teleport(pid, destination)
      refute Process.alive?(job.task.pid)
      send(pid, {job.task.ref, {:ok, %{accepted: true, pose: :standing, fences: %{}}}})
      move(client, %{ctx.pos | x: ctx.pos.x + 1})
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      client = correction(client, pid, destination)
      assert state(pid).motion_pending == nil
      assert Process.alive?(pid)
      Valimc.TestRegionGate.resume(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.4})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.4 end)

      assert {:error, :invalid_or_expired_teleport} =
               Connection.teleport(pid, Map.put(destination, :extra, 1))
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "expired completed geometry cannot commit after its player mailbox resumes", ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      job = wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      :sys.suspend(pid)

      try do
        Valimc.TestRegionGate.resume(owner)
        wait(fn -> not Process.alive?(job.task.pid) end)
        # The completed result waits in the mailbox past its admission deadline.
        expired = %{job.input | deadline: System.monotonic_time(:millisecond) - 1}

        :sys.replace_state(pid, fn s ->
          %{s | jobs: Valimc.Session.Jobs.update(s.jobs, :motion, %{input: expired})}
        end)
      after
        :sys.resume(pid)
      end

      _client = correction(client, pid, ctx.pos)
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "a TCP burst retains one active input and disconnect cancels outstanding work", ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.01})
      job = wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      for n <- 2..34, do: move(client, %{ctx.pos | x: ctx.pos.x + n * 0.01})
      assert Valimc.TestConn.job(state(pid), :motion).task.ref == job.task.ref
      assert state(pid).motion_pending.position.x == ctx.pos.x + 0.01
      refute state(pid).active
      Valimc.TestRegionGate.resume(owner)
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.34 end)
      Valimc.TestRegionGate.stall(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.4})
      job = wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      ref = Process.monitor(job.task.pid)
      Client.close(client)
      assert_receive {:DOWN, ^ref, :process, _, _}
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  # The queued input retries while the workers are full, then expires uncommitted.
  # Its token comes from that retry rather than from polling the brief queue. A
  # loaded host can deschedule the connection past the 250 ms window before the
  # input queues at all; that input is corrected too, and the move is tried again
  # (VMC-073).
  defp queued_motion(client, pid, pos, tries \\ 10) do
    :erlang.trace(pid, true, [:receive])
    move(client, %{pos | x: pos.x + 0.1})
    # Either way the input ends in a correction to the unmoved position.
    client = correction(client, pid, pos)
    :erlang.trace(pid, false, [:receive])
    retries = trace_retries(pid, [])
    assert Valimc.TestConn.job(state(pid), :motion) == nil

    case retries do
      [token | _] -> {client, token}
      [] when tries > 1 -> queued_motion(client, pid, pos, tries - 1)
    end
  end

  defp trace_retries(pid, acc) do
    receive do
      {:trace, ^pid, :receive, {:retry_motion, token}} -> trace_retries(pid, [token | acc])
      {:trace, ^pid, :receive, _} -> trace_retries(pid, acc)
    after
      0 -> acc
    end
  end

  test "worker saturation queues briefly, then expires without granting movement", ctx do
    # The play admission window, which this test exhausts (VMC-073).
    Valimc.TestScope.isolate(Connection.offline_uuid(hd(ctx.names)), owner_call_scale: 1)
    {client, pid} = login(hd(ctx.names))
    wait(fn -> Valimc.TestConn.job(state(pid), :pose) == nil end)

    holders = Valimc.TestPool.fill(pid)

    try do
      {client, token} = queued_motion(client, pid, ctx.pos)
      send(pid, {:retry_motion, token})
      Valimc.TestPool.release(holders)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.2 end)
    after
      Valimc.TestPool.release(holders)
    end
  end

  test "later intent waits for motion, and a replaced owner cannot authorize its old input",
       ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      Client.send_packet(client, :play, "player_input", <<32>>)
      assert state(pid).player.input.shared_flags == 0
      Valimc.TestRegionGate.resume(owner)

      wait(fn ->
        state(pid).player.x == ctx.pos.x + 0.1 and state(pid).player.pose == :crouching
      end)

      assert state(pid).player.pose == :crouching
      refute state(pid).teleport_pending
      Valimc.TestRegionGate.stall(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> Valimc.TestConn.job(state(pid), :motion) end)
      Process.exit(owner, :kill)
      client = correction(client, pid, %{ctx.pos | x: ctx.pos.x + 0.1})
      {:ok, {replacement, _}} = World.owner(ctx.key)
      refute replacement == owner
      move(client, %{ctx.pos | x: ctx.pos.x + 0.3})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.3 end)
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "an authoritative mode change invalidates geometry prepared while admission waits", ctx do
    {client, pid} = login(hd(ctx.names))
    :ok = World.set_block({floor(ctx.pos.x) + 1, 64, floor(ctx.pos.z)}, 1)
    wait(fn -> Valimc.TestConn.job(state(pid), :pose) == nil end)

    holders = Valimc.TestPool.fill(pid)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.5})
      wait(fn -> state(pid).motion_pending && state(pid).motion_pending.prepared end)
      # Model a server-owned transition; queued client input cannot change permissions.
      :sys.replace_state(pid, fn s ->
        %{
          s
          | player: %{
              s.player
              | game_mode: Valimc.GameMode.new(:spectator),
                abilities: Valimc.PlayerAbilities.for_mode(:spectator)
            },
            inventory: %{s.inventory | infinite_materials: false}
        }
      end)

      Valimc.TestPool.release(holders)
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.5 end)
      refute state(pid).teleport_pending
      assert state(pid).player.game_mode.current == :spectator
    after
      Valimc.TestPool.release(holders)
    end
  end
end
