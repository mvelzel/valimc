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

  defp sprint(client, entity, enabled),
    do:
      Client.send_packet(client, :play, "player_command", [
        Wire.varint(entity),
        Wire.varint(if(enabled, do: 1, else: 2)),
        <<0>>
      ])

  defp await_swimming(client, entity, flags, pose) do
    if get_in(client, [:entity_flags, entity]) == flags and
         get_in(client, [:entity_poses, entity]) == pose do
      client
    else
      {id, body, client} = Client.read(client)
      name = Data.name(:play, :clientbound, id)
      await_swimming(Client.auto_reply(client, :play, name, body), entity, flags, pose)
    end
  end

  test "water sprint selects swimming geometry and flags while dry crawling remains distinct",
       ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id
    {x, z} = {floor(ctx.pos.x), floor(ctx.pos.z)}

    for bx <- (x - 1)..(x + 2),
        bz <- (z - 1)..(z + 1),
        by <- 64..66,
        do: :ok = World.set_block({bx, by, bz}, 89)

    client = sprint(client, entity, true) |> await_swimming(entity, 24, 3)
    assert state(pid).player.motion.swimming
    assert state(pid).player.input.shared_flags == 8

    [_, observer] = ctx.names
    uuid = Valimc.Connection.offline_uuid(observer)
    path = PlayerStore.path(Valimc.config(:world_path), uuid)

    {:ok, bytes} =
      PlayerSnapshot.encode(
        uuid,
        PlayerSnapshot.capture(%{ctx.pos | x: ctx.pos.x + 2}, Inventory.new())
      )

    File.write!(path, bytes)
    {peer, _} = login(observer)
    assert peer.entity_flags[entity] == 24 and peer.entity_poses[entity] == 3

    :ok = World.set_block({x + 1, 65, z}, 1)

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<ctx.pos.x + 1::float-64, 64.0::float-64, ctx.pos.z::float-64, 1>>
    )

    Client.send_packet(client, :play, "client_tick_end", <<>>)
    wait(fn -> state(pid).player.x == ctx.pos.x + 1 end)
    assert state(pid).player.pose == :swimming

    # Stopping sprint clears the swimming bit even when low headroom forces a crawl.
    client = sprint(client, entity, false) |> await_swimming(entity, 0, 3)
    _peer = await_swimming(peer, entity, 0, 3)
    refute state(pid).player.motion.swimming
    :ok = World.set_block({x + 1, 65, z}, 89)
    client = await_pose(client, entity, 0)
    client = sprint(client, entity, true) |> await_swimming(entity, 24, 3)

    Client.send_packet(client, :play, "player_abilities", <<2>>)
    client = await_swimming(client, entity, 8, 0)
    assert state(pid).player.abilities.flying and not state(pid).player.motion.swimming
    Client.send_packet(client, :play, "player_abilities", <<0>>)
    client = await_swimming(client, entity, 24, 3)

    # Existing swimming persists at the surface; a fresh sprint needs submerged eyes.
    for bx <- (x - 1)..(x + 2),
        bz <- (z - 1)..(z + 1),
        by <- 65..66,
        do: :ok = World.set_block({bx, by, bz}, 0)

    wait(fn -> state(pid).pose_job == nil and state(pid).pose_checked != nil end)
    assert state(pid).player.motion.swimming
    client = sprint(client, entity, false) |> await_swimming(entity, 0, 0)
    client = sprint(client, entity, true) |> await_swimming(entity, 8, 0)
    refute state(pid).player.motion.swimming
    :ok = World.set_block({x + 1, 65, z}, 89)
    client = await_swimming(client, entity, 24, 3)

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<ctx.pos.x + 4::float-64, 64.0::float-64, ctx.pos.z::float-64, 1>>
    )

    Client.send_packet(client, :play, "client_tick_end", <<>>)
    _client = await_swimming(client, entity, 8, 0)
    assert state(pid).player.x == ctx.pos.x + 4 and not state(pid).player.motion.swimming
  end

  test "a delayed underwater sprint result cannot restore swimming after flight starts", ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id

    for y <- 64..66,
        do: :ok = World.set_block({floor(ctx.pos.x), y, floor(ctx.pos.z)}, 89)

    wait(fn -> state(pid).pose_job == nil and state(pid).pose_checked != nil end)
    {:ok, {owner, _}} = World.owner(ctx.key)
    Valimc.TestRegionGate.stall(owner)

    try do
      client = sprint(client, entity, true)
      job = wait(fn -> state(pid).pose_job end)
      Client.send_packet(client, :play, "player_abilities", <<2>>)
      wait(fn -> state(pid).player.abilities.flying end)
      Valimc.TestRegionGate.resume(owner)
      wait(fn -> state(pid).pose_job == nil or state(pid).pose_job.task.ref != job.task.ref end)
      wait(fn -> state(pid).pose_job == nil and state(pid).pose_checked != nil end)
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
    assert [_, _, _, pose, frozen, use, health] = Packets.move_entity(%{p | x: p.x + 10}, view)
    assert pose == Packets.player_pose(p)
    assert frozen == Packets.player_environment(p)
    assert use == Packets.player_use(p)
    assert health == Packets.player_health(p)
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
      job = wait(fn -> state(pid).pose_job end)
      assert state(pid).player.pose == :crouching
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await(client, :play, "system_chat")
      _other = input(other, true) |> await_pose(state(other_pid).player.entity_id, 5)
      client = input(client, true)
      wait(fn -> state(pid).player.input.shared_flags == 2 end)
      Valimc.TestRegionGate.resume(owner)
      wait(fn -> state(pid).pose_job == nil or state(pid).pose_job.task.ref != job.task.ref end)
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
    :ok = World.set_block(roof, 1)
    client = await_pose(client, entity, 3)
    {:ok, {owner, _}} = World.owner(ctx.key)
    Process.exit(owner, :kill)
    wait(fn -> not Process.alive?(owner) and state(pid).pose_checked == nil end)
    assert Process.alive?(pid)
    {:ok, {replacement, _}} = World.owner(ctx.key)
    refute replacement == owner
    client = await_pose(client, entity, 0)
    Valimc.TestRegionGate.stall(replacement)

    try do
      client = input(client, true)
      job = wait(fn -> state(pid).pose_job end)
      ref = Process.monitor(job.task.pid)
      Client.close(client)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1000
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
    wait(fn -> state(pid).pose_job == nil end)

    holders = Valimc.TestPool.fill(pid)

    try do
      client = input(client, false)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await(client, :play, "system_chat")
      Process.sleep(110)
      assert state(pid).player.pose == :crouching and state(pid).pose_job == nil
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
      job = wait(fn -> state(pid).pose_job end)
      :sys.suspend(pid)

      try do
        Valimc.TestRegionGate.resume(owner)
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
