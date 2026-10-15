defmodule Valimc.PlayerPoseConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, Packets, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-pose-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {40_000 + rem(nonce, 10_000), 650}
    names = for suffix <- ["A", "B"], do: "Pose#{nonce}#{suffix}"
    {rx, rz} = key
    pos = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    for {name, index} <- Enum.with_index(names) do
      uuid = Valimc.Connection.offline_uuid(name)
      pose = %{pos | x: pos.x + index * 256}
      path = PlayerStore.path(base, uuid)
      {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(pose, Inventory.new()))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    on_exit(fn ->
      for player <- Players.all(),
          player.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for name <- names,
          {pid, _} <-
            Registry.lookup(Valimc.PlayerStoreRegistry, Valimc.Connection.offline_uuid(name)),
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
    player = Enum.find(Players.all(), &(&1.name == name))
    Client.send_packet(client, :play, "player_loaded", <<>>)
    {client, player.pid}
  end

  defp state(pid), do: :sys.get_state(pid)

  defp wait(fun, left \\ 500) do
    if result = fun.() do
      result
    else
      assert left > 0
      Process.sleep(5)
      wait(fun, left - 1)
    end
  end

  defp await_pose(client, entity, pose) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)
    client = Client.auto_reply(client, :play, name, body)

    if get_in(client, [:entity_poses, entity]) == pose,
      do: client,
      else: await_pose(client, entity, pose)
  end

  defp input(client, shift),
    do: Client.send_packet(client, :play, "player_input", <<if(shift, do: 32, else: 0)>>)

  test "live occupancy selects and replicates crouch/crawl/standing, with selected eye height",
       ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    wait(fn -> state(pid).pose_checked != nil end)
    assert state(pid).player.pose == :standing
    client = input(client, true) |> await_pose(entity, 5)
    assert state(pid).player.pose == :crouching
    assert elem(Valimc.PlayerInteraction.eye(state(pid).player), 1) == 65.26999998092651
    client = input(client, false) |> await_pose(entity, 0)

    roof = {floor(ctx.pos.x), 65, floor(ctx.pos.z)}
    :ok = World.set_block(roof, 15178)
    client = await_pose(client, entity, 5)
    assert state(pid).player.pose == :crouching
    :ok = World.set_block(roof, 1)
    client = await_pose(client, entity, 3)
    assert state(pid).player.pose == :swimming
    assert elem(Valimc.PlayerInteraction.eye(state(pid).player), 1) == 64.40000000596046
    :ok = World.set_block(roof, 0)
    _client = await_pose(client, entity, 0)
    wait(fn -> state(pid).pose_job == nil and state(pid).pose_checked != nil end)
    checked = state(pid).pose_checked
    Process.sleep(160)
    assert state(pid).pose_job == nil and state(pid).pose_checked == checked

    p = %{state(pid).player | x: 0.5, z: 0.5}

    assert Valimc.PlayerInteraction.within_block?(
             :creative,
             Valimc.PlayerInteraction.eye(p),
             {3, 71, 0}
           )

    refute Valimc.PlayerInteraction.within_block?(
             :creative,
             Valimc.PlayerInteraction.eye(%{p | pose: :crouching}),
             {3, 71, 0}
           )
  end

  test "late and recreated peer tracking initialize selected pose without fabricated movement",
       ctx do
    [first, second] = ctx.names
    {sender, pid} = login(first)
    sender = input(sender, true)
    entity = state(pid).player.entity_id
    _sender = await_pose(sender, entity, 5)

    # Put the second saved player nearby before its first login.
    uuid = Valimc.Connection.offline_uuid(second)
    path = PlayerStore.path(Valimc.config(:world_path), uuid)
    nearby = %{ctx.pos | x: ctx.pos.x + 2}
    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(nearby, Inventory.new()))
    File.write!(path, bytes)
    {receiver, _} = login(second)
    assert receiver.entity_poses[entity] == 5
    p = state(pid).player
    view = Packets.view(p)
    assert Packets.move_entity(p, view) == []
    assert [packet] = Packets.move_entity(%{p | pose: :standing}, view)
    assert packet == Packets.player_pose(%{p | pose: :standing})
    assert [_, _, _, pose] = Packets.move_entity(%{p | x: p.x + 10}, view)
    assert pose == Packets.player_pose(p)
  end

  test "stalled source cannot apply stale intent or block an independent player", ctx do
    [first, second] = ctx.names
    {client, pid} = login(first)
    {other, other_pid} = login(second)
    entity = state(pid).player.entity_id
    client = input(client, true) |> await_pose(entity, 5)
    {:ok, {owner, _}} = World.owner(ctx.key)
    :sys.suspend(owner)

    try do
      client = input(client, false)
      job = wait(fn -> state(pid).pose_job end)
      assert state(pid).player.pose == :crouching
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await(client, :play, "system_chat")
      _other = input(other, true) |> await_pose(state(other_pid).player.entity_id, 5)
      client = input(client, true)
      wait(fn -> state(pid).player.input.shared_flags == 2 end)
      :sys.resume(owner)
      wait(fn -> state(pid).pose_job == nil or state(pid).pose_job.task.ref != job.task.ref end)
      assert state(pid).player.pose == :crouching
      assert Process.alive?(pid) and Process.alive?(other_pid)
      Client.close(client)
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "source incarnation loss invalidates an idle sample and disconnect cancels a pending job",
       ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    roof = {floor(ctx.pos.x), 65, floor(ctx.pos.z)}
    :ok = World.set_block(roof, 1)
    client = await_pose(client, entity, 3)
    {:ok, {owner, _}} = World.owner(ctx.key)
    Process.exit(owner, :kill)
    wait(fn -> not Process.alive?(owner) and state(pid).pose_checked == nil end)
    assert Process.alive?(pid)
    {:ok, {replacement, _}} = World.owner(ctx.key)
    refute replacement == owner
    client = await_pose(client, entity, 0)
    :sys.suspend(replacement)

    try do
      client = input(client, true)
      job = wait(fn -> state(pid).pose_job end)
      ref = Process.monitor(job.task.pid)
      Client.close(client)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1000
      refute Process.alive?(job.task.pid)
    after
      if Process.alive?(replacement), do: :sys.resume(replacement)
    end
  end

  test "bounded worker saturation retains the selected pose and resumes without an input queue",
       ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    client = input(client, true) |> await_pose(entity, 5)
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
      client = input(client, false)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await(client, :play, "system_chat")
      Process.sleep(110)
      assert state(pid).player.pose == :crouching and state(pid).pose_job == nil
      assert DynamicSupervisor.count_children(Valimc.CollisionWorkers).active == length(holders)
      for holder <- holders, do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, holder)
      _client = await_pose(client, entity, 0)
      assert state(pid).player.pose == :standing
    after
      for holder <- holders,
          Process.alive?(holder),
          do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, holder)
    end
  end

  test "a completed result cannot outlive its budget while the player owner is suspended", ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    client = input(client, true) |> await_pose(entity, 5)
    {:ok, {owner, _}} = World.owner(ctx.key)
    :sys.suspend(owner)

    try do
      client = input(client, false)
      job = wait(fn -> state(pid).pose_job end)
      :sys.suspend(pid)

      try do
        :sys.resume(owner)
        wait(fn -> not Process.alive?(job.task.pid) end)
        roof = {floor(ctx.pos.x), 65, floor(ctx.pos.z)}
        :ok = World.set_block(roof, 15178)
        Process.sleep(260)
      after
        :sys.resume(pid)
      end

      # The expired standing result precedes the roof event in this mailbox.
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      await_stats_without_standing(client, entity)
      assert state(pid).player.pose == :crouching
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  defp await_stats_without_standing(client, entity) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)

    if name == "set_entity_data" do
      refute Wire.read_varint(body) == {:ok, entity, <<6, 20, 0, 255>>}
    end

    if name != "system_chat",
      do: await_stats_without_standing(Client.auto_reply(client, :play, name, body), entity)
  end
end
