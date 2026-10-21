defmodule Valimc.PlayerPoseConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, Packets, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-pose-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {40_000 + rem(nonce, 3_333) * 3, 650}
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
      Valimc.TestScope.stop_players(base)
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

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  # One read: the job may finish between two (VMC-073).
  defp pose_job_replaced?(pid, job) do
    case Valimc.TestConn.job(state(pid), :pose) do
      nil -> true
      current -> current.task.ref != job.task.ref
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

  defp sprint(client, entity, enabled),
    do:
      Client.send_packet(client, :play, "player_command", [
        Wire.varint(entity),
        Wire.varint(if(enabled, do: 1, else: 2)),
        <<0>>
      ])

  test "a delayed underwater sprint result cannot restore swimming after flight starts", ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id

    for y <- 64..66,
        do: :ok = Valimc.TestBlocks.set({floor(ctx.pos.x), y, floor(ctx.pos.z)}, 89)

    wait(fn ->
      Valimc.TestConn.job(state(pid), :pose) == nil and state(pid).pose_checked != nil
    end)

    {:ok, {owner, _}} = World.owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      client = sprint(client, entity, true)
      job = wait(fn -> Valimc.TestConn.job(state(pid), :pose) end)
      Client.send_packet(client, :play, "player_abilities", <<2>>)
      wait(fn -> state(pid).player.abilities.flying end)
      Valimc.TestRegionGate.resume(owner)
      wait(fn -> pose_job_replaced?(pid, job) end)

      wait(fn ->
        Valimc.TestConn.job(state(pid), :pose) == nil and state(pid).pose_checked != nil
      end)

      assert state(pid).player.abilities.flying
      assert state(pid).player.pose == :standing
      refute state(pid).player.motion.swimming
      assert Packets.shared_flags(state(pid).player) == 8
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

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
    :ok = Valimc.TestBlocks.set(roof, 15178)
    client = await_pose(client, entity, 5)
    assert state(pid).player.pose == :crouching
    :ok = Valimc.TestBlocks.set(roof, 1)
    client = await_pose(client, entity, 3)
    assert state(pid).player.pose == :swimming
    assert elem(Valimc.PlayerInteraction.eye(state(pid).player), 1) == 64.40000000596046
    :ok = Valimc.TestBlocks.set(roof, 0)
    _client = await_pose(client, entity, 0)

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

  test "stalled source cannot apply stale intent or block an independent player", ctx do
    [first, second] = ctx.names
    {client, pid} = login(first)
    {other, other_pid} = login(second)
    entity = state(pid).player.entity_id
    client = input(client, true) |> await_pose(entity, 5)
    {:ok, {owner, _}} = World.owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      client = input(client, false)
      job = wait(fn -> Valimc.TestConn.job(state(pid), :pose) end)
      assert state(pid).player.pose == :crouching
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await_stats(client)
      _other = input(other, true) |> await_pose(state(other_pid).player.entity_id, 5)
      client = input(client, true)
      wait(fn -> state(pid).player.input.shared_flags == 2 end)
      Valimc.TestRegionGate.resume(owner)
      wait(fn -> pose_job_replaced?(pid, job) end)
      assert state(pid).player.pose == :crouching
      assert Process.alive?(pid) and Process.alive?(other_pid)
      Client.close(client)
    after
      Valimc.TestRegionGate.resume(owner)
    end
  end

  test "source incarnation loss invalidates an idle sample and disconnect cancels a pending job",
       ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    roof = {floor(ctx.pos.x), 65, floor(ctx.pos.z)}
    :ok = Valimc.TestBlocks.set(roof, 1)
    client = await_pose(client, entity, 3)
    {:ok, {owner, _}} = World.owner(ctx.key)
    Process.exit(owner, :kill)
    wait(fn -> not Process.alive?(owner) and state(pid).pose_checked == nil end)
    assert Process.alive?(pid)
    {:ok, {replacement, _}} = World.owner(ctx.key)
    refute replacement == owner
    # The roof was durable before the kill (VMC-077f); the new owner's change is seen.
    :ok = Valimc.TestBlocks.set(roof, 0)
    client = await_pose(client, entity, 0)
    Valimc.TestRegionGate.stall(replacement)

    try do
      client = input(client, true)
      job = wait(fn -> Valimc.TestConn.job(state(pid), :pose) end)
      ref = Process.monitor(job.task.pid)
      Client.close(client)
      assert_receive {:DOWN, ^ref, :process, _, _}
      refute Process.alive?(job.task.pid)
    after
      Valimc.TestRegionGate.resume(replacement)
    end
  end

  test "bounded worker saturation retains the selected pose and resumes without an input queue",
       ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    client = input(client, true) |> await_pose(entity, 5)
    wait(fn -> Valimc.TestConn.job(state(pid), :pose) == nil end)

    holders = Valimc.TestPool.fill(pid)

    try do
      client = input(client, false)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await_stats(client)

      assert state(pid).player.pose == :crouching and
               Valimc.TestConn.job(state(pid), :pose) == nil

      assert Valimc.TestPool.active(pid) == length(holders)
      Valimc.TestPool.release(holders)
      _client = await_pose(client, entity, 0)
      assert state(pid).player.pose == :standing
    after
      Valimc.TestPool.release(holders)
    end
  end

  test "a completed result cannot outlive its budget while the player owner is suspended", ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    client = input(client, true) |> await_pose(entity, 5)
    {:ok, {owner, _}} = World.owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      client = input(client, false)
      job = wait(fn -> Valimc.TestConn.job(state(pid), :pose) end)
      :sys.suspend(pid)

      try do
        Valimc.TestRegionGate.resume(owner)
        wait(fn -> not Process.alive?(job.task.pid) end)
        roof = {floor(ctx.pos.x), 65, floor(ctx.pos.z)}
        :ok = Valimc.TestBlocks.set(roof, 15178)
        # The completed result waits in the mailbox past its deadline.
        expired = System.monotonic_time(:millisecond) - 1

        :sys.replace_state(pid, fn s ->
          %{s | jobs: Valimc.Session.Jobs.update(s.jobs, :pose, %{deadline: expired})}
        end)
      after
        :sys.resume(pid)
      end

      # The expired standing result precedes the roof event in this mailbox.
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      await_stats_without_standing(client, entity)
      assert state(pid).player.pose == :crouching
    after
      Valimc.TestRegionGate.resume(owner)
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
