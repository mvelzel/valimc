defmodule Valimc.PlayerPoseConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, Players, PlayerStore}
  alias Valimc.Player.State, as: PlayerState
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
      {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(pose, Inventory.new()))
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
    player = Enum.find(Players.all(), &(&1.name == name))
    Client.send_packet(client, :play, "player_loaded", <<>>)
    {client, player.pid}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  # One read: the job may finish between two (VMC-073).
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

  test "starting flight ends underwater sprint swimming", ctx do
    {client, pid} = login(hd(ctx.names))
    entity = state(pid).player.entity_id

    for y <- 64..66,
        do: :ok = Valimc.TestBlocks.set({floor(ctx.pos.x), y, floor(ctx.pos.z)}, 89)

    wait(fn -> state(pid).pose_checked != nil end)
    client = sprint(client, entity, true)
    Client.send_packet(client, :play, "player_abilities", <<2>>)
    wait(fn -> state(pid).player.abilities.flying end)
    wait(fn -> state(pid).pose_checked != nil end)
    assert state(pid).player.pose == :standing
    refute state(pid).player.motion.swimming
    assert Packets.shared_flags(state(pid).player) == 8
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
end
