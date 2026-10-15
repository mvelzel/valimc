defmodule Valimc.PlayerMotionConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-motion-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {42_000 + rem(nonce, 10_000), 750}
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
      File.rm_rf!(base)
    end)

    %{names: names, key: key, pos: pos}
  end

  defp login(name) do
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    {client, pid}
  end

  defp state(pid), do: :sys.get_state(pid)

  defp wait(fun, left \\ 400) do
    if result = fun.(),
      do: result,
      else:
        (
          assert left > 0
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end

  defp move(client, p) do
    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<p.x::float-64, p.y::float-64, p.z::float-64, 1>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])
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
    :sys.suspend(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> state(pid).motion_job end)

      Client.send_packet(client, :play, "player_action", [
        <<4>>,
        Wire.position({0, 0, 0}),
        <<0, 0>>
      ])

      assert state(pid).recovery == nil
      :sys.resume(owner)

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
      if Process.alive?(owner), do: :sys.resume(owner)
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
    :sys.suspend(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      job = wait(fn -> state(pid).motion_job end)
      move(other, %{other_pos | x: other_pos.x + 0.2})
      wait(fn -> state(independent).player.x == other_pos.x + 0.2 end)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      client = correction(client, pid, ctx.pos)
      {_, client} = Client.await(client, :play, "system_chat")
      refute Process.alive?(job.task.pid)
      :sys.resume(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.2 end)
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "server relocation cancels old work, ignores retired results, and fences unacknowledged input",
       ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      job = wait(fn -> state(pid).motion_job end)
      destination = %{ctx.pos | x: ctx.pos.x + 0.3}
      :ok = Connection.teleport(pid, destination)
      refute Process.alive?(job.task.pid)
      send(pid, {job.task.ref, {:ok, %{accepted: true, pose: :standing, fences: %{}}}})
      move(client, %{ctx.pos | x: ctx.pos.x + 1})
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      client = correction(client, pid, destination)
      assert state(pid).motion_pending == nil
      assert Process.alive?(pid)
      :sys.resume(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.4})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.4 end)

      assert {:error, :invalid_or_expired_teleport} =
               Connection.teleport(pid, Map.put(destination, :extra, 1))
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "expired completed geometry cannot commit after its player mailbox resumes", ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      job = wait(fn -> state(pid).motion_job end)
      :sys.suspend(pid)

      try do
        :sys.resume(owner)
        wait(fn -> not Process.alive?(job.task.pid) end)
        Process.sleep(260)
      after
        :sys.resume(pid)
      end

      _client = correction(client, pid, ctx.pos)
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "a TCP burst retains one active input and disconnect cancels outstanding work", ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.01})
      job = wait(fn -> state(pid).motion_job end)
      for n <- 2..34, do: move(client, %{ctx.pos | x: ctx.pos.x + n * 0.01})
      assert state(pid).motion_job.task.ref == job.task.ref
      assert state(pid).motion_pending.position.x == ctx.pos.x + 0.01
      refute state(pid).active
      :sys.resume(owner)
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.34 end)
      :sys.suspend(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.4})
      job = wait(fn -> state(pid).motion_job end)
      ref = Process.monitor(job.task.pid)
      Client.close(client)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "worker saturation queues briefly, then expires without granting movement", ctx do
    {client, pid} = login(hd(ctx.names))
    wait(fn -> state(pid).pose_job == nil end)

    holders =
      for _ <- 1..Valimc.Physics.CollisionQuery.worker_limit() do
        {:ok, holder} =
          Task.Supervisor.start_child(Valimc.CollisionWorkers, fn ->
            receive do
              :stop -> :ok
            end
          end)

        holder
      end

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      input = wait(fn -> state(pid).motion_pending end)
      assert state(pid).motion_job == nil
      assert state(pid).player.x == ctx.pos.x
      client = correction(client, pid, ctx.pos)
      send(pid, {:retry_motion, input.token})
      for holder <- holders, do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, holder)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.2 end)
    after
      for holder <- holders,
          Process.alive?(holder),
          do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, holder)
    end
  end

  test "later intent waits for motion, and a replaced owner cannot authorize its old input",
       ctx do
    {client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      move(client, %{ctx.pos | x: ctx.pos.x + 0.1})
      wait(fn -> state(pid).motion_job end)
      Client.send_packet(client, :play, "player_input", <<32>>)
      assert state(pid).player.input.shared_flags == 0
      :sys.resume(owner)

      wait(fn ->
        state(pid).player.x == ctx.pos.x + 0.1 and state(pid).player.pose == :crouching
      end)

      assert state(pid).player.pose == :crouching
      refute state(pid).teleport_pending
      :sys.suspend(owner)
      move(client, %{ctx.pos | x: ctx.pos.x + 0.2})
      wait(fn -> state(pid).motion_job end)
      Process.exit(owner, :kill)
      client = correction(client, pid, %{ctx.pos | x: ctx.pos.x + 0.1})
      {:ok, {replacement, _}} = World.owner(ctx.key)
      refute replacement == owner
      move(client, %{ctx.pos | x: ctx.pos.x + 0.3})
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.3 end)
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end
end
