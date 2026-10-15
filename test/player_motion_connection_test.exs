defmodule Valimc.PlayerMotionConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, PackedVelocity, Wire}
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
    pid = owner(name)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    {client, pid}
  end

  defp state(pid), do: :sys.get_state(pid)

  defp owner(name) do
    wait(fn ->
      case Enum.find(Players.all(), &(&1.name == name)) do
        nil -> nil
        player -> player.pid
      end
    end)
  end

  defp await_frozen(client, entity, predicate) do
    value = get_in(client, [:entity_frozen, entity])

    if is_integer(value) and predicate.(value) do
      client
    else
      {id, body, client} = Client.read(client)
      name = Data.name(:play, :clientbound, id)
      await_frozen(Client.auto_reply(client, :play, name, body), entity, predicate)
    end
  end

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

  test "server impulse replicates to self/peer while scratch gravity preserves accepted position",
       ctx do
    [first, second] = ctx.names
    {client, pid} = login(first)
    uuid = Connection.offline_uuid(second)

    {:ok, bytes} =
      PlayerSnapshot.encode(
        uuid,
        PlayerSnapshot.capture(%{ctx.pos | x: ctx.pos.x + 2}, Inventory.new())
      )

    File.write!(PlayerStore.path(Valimc.config(:world_path), uuid), bytes)
    {peer, peer_pid} = login(second)
    wait(fn -> Map.has_key?(state(peer_pid).peers, pid) end)
    top = %{ctx.pos | y: 68.0}
    client = Client.teleport(client, pid, top)
    wait(fn -> elem(state(pid).player.motion.velocity, 1) < -0.1 end)
    assert state(pid).player.y == 68.0
    assert state(pid).player.motion.fall_distance == 0.0
    assert state(pid).player.motion.known_movement == {0.0, 0.0, 0.0}

    assert :ok = Connection.set_velocity(pid, {0.7, 0.8, -0.2})
    entity = state(pid).player.entity_id

    for endpoint <- [client, peer] do
      {body, _} = Client.await(endpoint, :play, "set_entity_motion")
      assert {^entity, payload} = Wire.take_varint(body)
      assert {:ok, {x, y, z}} = PackedVelocity.decode(payload)
      assert abs(x - 0.7) < 0.0001 and abs(y - 0.8) < 0.0001 and abs(z + 0.2) < 0.0001
    end

    wait(fn -> elem(state(pid).player.motion.velocity, 1) < 0.7 end)
    assert state(pid).player.y == 68.0
    assert state(pid).player.x == top.x
    assert state(pid).player.motion.fall_distance == 0.0
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

  test "accepted jump changes velocity without manufacturing accepted height on later ticks",
       ctx do
    {client, pid} = login(hd(ctx.names))
    move(client, ctx.pos, 1)
    wait(fn -> state(pid).player.motion.on_ground end)
    jump = %{ctx.pos | y: 64.42}
    move(client, jump, 0)
    wait(fn -> state(pid).player.y == jump.y end)
    assert elem(state(pid).player.motion.velocity, 1) > 0.1
    Process.sleep(100)
    assert state(pid).player.y == jump.y
    assert state(pid).player.motion.fall_distance == 0.0
  end

  for {kind, fluid, lifted_velocity} <- [{:water, 89, 0.01}, {:lava, 105, -0.005}] do
    test "live #{kind} ticks consume input without inventing accepted position", ctx do
      {client, pid} = login(hd(ctx.names))
      {x, z} = {floor(ctx.pos.x), floor(ctx.pos.z)}

      for px <- (x - 1)..(x + 1),
          py <- 64..66,
          pz <- (z - 1)..(z + 1),
          do: :ok = World.set_block({px, py, pz}, unquote(fluid))

      anchor = %{ctx.pos | y: 64.2}
      _client = Client.teleport(client, pid, anchor)
      assert :ok = Connection.set_velocity(pid, {0.3, -0.1, 0.0})

      wait(fn ->
        {vx, vy, _} = state(pid).player.motion.velocity
        abs(vx) < 0.25 and vy > -0.1 and vy < 0
      end)

      assert state(pid).player.y == anchor.y
      Client.send_packet(client, :play, "player_input", <<16>>)
      wait(fn -> elem(state(pid).player.motion.velocity, 1) > unquote(lifted_velocity) end)
      assert state(pid).player.y == anchor.y
      Client.send_packet(client, :play, "player_input", <<32>>)
      wait(fn -> elem(state(pid).player.motion.velocity, 1) < -0.02 end)
      assert state(pid).player.y == anchor.y
    end
  end

  test "live climbing consumes jump and Shift while source changes resume falling", ctx do
    {client, pid} = login(hd(ctx.names))
    {x, z} = {floor(ctx.pos.x), floor(ctx.pos.z)}
    for y <- 65..68, do: :ok = World.set_block({x, y, z}, 7308)
    anchor = %{ctx.pos | y: 66.2}
    client = Client.teleport(client, pid, anchor)
    assert :ok = Connection.set_velocity(pid, {0.0, -2.0, 0.0})
    wait(fn -> abs(elem(state(pid).player.motion.velocity, 1) + 0.22540001) < 1.0e-8 end)
    Client.send_packet(client, :play, "player_input", <<16>>)

    wait(fn ->
      abs(elem(state(pid).player.motion.velocity, 1) - 0.11760000228881837) < 1.0e-12
    end)

    Client.send_packet(client, :play, "player_input", <<32>>)
    wait(fn -> state(pid).player.motion.velocity == {0.0, -0.0784000015258789, 0.0} end)
    assert state(pid).player.y == anchor.y
    refute state(pid).teleport_pending

    # Retiring the source contact must not leave a cached climbing/Shift hold.
    :ok = World.set_block({x, 66, z}, 0)
    wait(fn -> elem(state(pid).player.motion.velocity, 1) < -0.3 end)
    assert state(pid).player.y == anchor.y
    refute state(pid).teleport_pending
  end

  test "climbing resets accepted falls on a fresh logical tick and excludes flight", ctx do
    {client, pid} = login(hd(ctx.names))
    {x, z} = {floor(ctx.pos.x), floor(ctx.pos.z)}
    for y <- 65..68, do: :ok = World.set_block({x, y, z}, 7308)
    client = Client.teleport(client, pid, %{ctx.pos | y: 67.2})
    move(client, %{ctx.pos | y: 66.2}, 0)
    wait(fn -> state(pid).player.y == 66.2 and state(pid).player.motion.fall_distance == 0.0 end)
    Client.send_packet(client, :play, "player_abilities", <<2>>)
    wait(fn -> state(pid).player.abilities.flying end)
    assert :ok = Connection.set_velocity(pid, {0.6, -1.0, 0.0})

    wait(fn ->
      {vx, vy, _} = state(pid).player.motion.velocity
      vx < 0.6 and vx > 0.15 and vy < -0.15
    end)

    assert state(pid).player.y == 66.2
    refute state(pid).teleport_pending
  end

  test "Shift ledge validation rejects unsupported travel and release retires the guard", ctx do
    name = hd(ctx.names)
    uuid = Connection.offline_uuid(name)

    p =
      Map.merge(ctx.pos, %{
        game_mode: Valimc.GameMode.new(:survival),
        abilities: Valimc.PlayerAbilities.for_mode(:survival)
      })

    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(p, Inventory.new()))
    File.write!(PlayerStore.path(Valimc.config(:world_path), uuid), bytes)

    for x <- (floor(p.x) + 1)..(floor(p.x) + 4),
        z <- (floor(p.z) - 2)..(floor(p.z) + 2),
        do: :ok = World.set_block({x, 63, z}, 0)

    {client, pid} = login(name)
    Client.send_packet(client, :play, "player_input", <<32>>)
    wait(fn -> state(pid).player.pose == :crouching end)
    move(client, %{ctx.pos | x: p.x + 2.0})
    client = correction(client, pid, ctx.pos)
    assert state(pid).player.motion.paths.count == 0
    Client.send_packet(client, :play, "player_input", <<0>>)
    wait(fn -> state(pid).player.input.shared_flags == 0 end)
    move(client, %{ctx.pos | x: p.x + 2.0})
    wait(fn -> state(pid).player.x == p.x + 2.0 end)
    refute state(pid).teleport_pending
    _client = Client.teleport(client, pid, ctx.pos)
  end

  test "live slowing contacts reset falls, refresh material and stop reapplying in flight", ctx do
    {client, pid} = login(hd(ctx.names))
    {x, z} = {floor(ctx.pos.x), floor(ctx.pos.z)}
    for y <- 65..68, do: :ok = World.set_block({x, y, z}, 2362)
    client = Client.teleport(client, pid, %{ctx.pos | y: 67.2})
    move(client, %{ctx.pos | y: 66.2}, 0)

    wait(fn ->
      s = state(pid)

      s.player.y == 66.2 and s.player.motion.fall_distance == 0.0 and
        elem(s.player.motion.stuck_multiplier, 0) == 0.25
    end)

    assert :ok = Connection.set_velocity(pid, {0.4, -1.0, 0.0})
    wait(fn -> state(pid).player.motion.velocity == {0.0, -0.0784000015258789, 0.0} end)
    for y <- 65..68, do: :ok = World.set_block({x, y, z}, 24298)
    wait(fn -> elem(state(pid).player.motion.stuck_multiplier, 0) == 0.800000011920929 end)
    Client.send_packet(client, :play, "player_abilities", <<2>>)
    wait(fn -> state(pid).player.abilities.flying end)
    wait(fn -> state(pid).player.motion.stuck_multiplier == {0.0, 0.0, 0.0} end)
    Client.send_packet(client, :play, "player_abilities", <<0>>)
    wait(fn -> not state(pid).player.abilities.flying end)
    wait(fn -> elem(state(pid).player.motion.stuck_multiplier, 0) == 0.800000011920929 end)
    _client = Client.teleport(client, pid, %{ctx.pos | x: ctx.pos.x + 3})
    wait(fn -> state(pid).player.motion.settled end)
    assert state(pid).player.motion.paths.count == 0
    assert state(pid).player.motion.stuck_multiplier == {0.0, 0.0, 0.0}
    refute state(pid).teleport_pending
  end

  test "new impulses retire stalled geometry and expired/invalid calls cannot replace velocity",
       ctx do
    {_client, pid} = login(hd(ctx.names))
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      assert :ok = Connection.set_velocity(pid, {0.4, 0.8, 0.0})
      job = wait(fn -> state(pid).pose_job end)
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

      Process.sleep(30)
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
      :sys.resume(owner)
      wait(fn -> elem(state(pid).player.motion.velocity, 1) < 0.5 end)
      assert Process.alive?(pid)
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "stationary server ticks freeze, replicate to a peer and thaw after relocation", ctx do
    [first, second] = ctx.names
    {client, pid} = login(first)
    uuid = Connection.offline_uuid(second)
    path = PlayerStore.path(Valimc.config(:world_path), uuid)

    {:ok, bytes} =
      PlayerSnapshot.encode(
        uuid,
        PlayerSnapshot.capture(%{ctx.pos | x: ctx.pos.x + 2}, Inventory.new())
      )

    File.write!(path, bytes)
    {peer, _} = login(second)
    entity = state(pid).player.entity_id
    :ok = World.set_block({floor(ctx.pos.x), 64, floor(ctx.pos.z)}, 30519)
    wait(fn -> state(pid).player.environment.frozen_ticks >= 4 end)
    client = await_frozen(client, entity, &(&1 >= 4))
    peer = await_frozen(peer, entity, &(&1 >= 4))
    assert state(pid).player.y == 64.0

    # A legal creative armor write changes immunity, not the contact sample.
    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<5::signed-16>>,
      ItemStack.encode(ItemStack.new("leather_helmet"))
    ])

    wait(fn -> state(pid).inventory.slots[5] != nil end)
    wait(fn -> state(pid).player.environment.frozen_ticks == 0 end)
    assert state(pid).player.environment.powder_snow
    client = await_frozen(client, entity, &(&1 == 0))

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<5::signed-16>>,
      ItemStack.encode(nil)
    ])

    wait(fn -> state(pid).player.environment.frozen_ticks >= 4 end)
    client = await_frozen(client, entity, &(&1 >= 4))
    peer = await_frozen(peer, entity, &(&1 >= 4))

    client = Client.teleport(client, pid, %{ctx.pos | x: ctx.pos.x + 2})
    wait(fn -> state(pid).player.environment.frozen_ticks == 0 end)
    _client = await_frozen(client, entity, &(&1 == 0))
    _peer = await_frozen(peer, entity, &(&1 == 0))
    refute state(pid).player.environment.powder_snow
  end

  test "stalled environment reads preserve effects until a fresh source can answer", ctx do
    {client, pid} = login(hd(ctx.names))
    :ok = World.set_block({floor(ctx.pos.x), 64, floor(ctx.pos.z)}, 30519)
    wait(fn -> state(pid).player.environment.frozen_ticks >= 3 end)
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      job = wait(fn -> state(pid).pose_job end)
      before = state(pid).player.environment.frozen_ticks
      Process.sleep(80)
      assert state(pid).player.environment.frozen_ticks == before
      client = Client.teleport(client, pid, %{ctx.pos | x: ctx.pos.x + 2})
      send(pid, {job.task.ref, {:ok, %{pose: :standing, powder_snow: true, fences: %{}}}})
      assert state(pid).player.environment.frozen_ticks == before
      :sys.resume(owner)
      wait(fn -> state(pid).player.environment.frozen_ticks == 0 end)
      assert Process.alive?(pid)
      move(client, %{ctx.pos | x: ctx.pos.x + 2.2})
      wait(fn -> state(pid).player.x == ctx.pos.x + 2.2 end)
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "only accepted displacement accrues falls; reports and tick boundaries retain their meaning",
       ctx do
    {client, pid} = login(hd(ctx.names))
    top = %{ctx.pos | y: 68.0}
    :ok = Connection.teleport(pid, top)
    client = correction(client, pid, top)
    down = %{top | y: 67.0}
    move(client, down, 2)
    wait(fn -> state(pid).player.y == down.y end)
    motion = state(pid).player.motion
    assert motion.fall_distance == 1.0
    assert motion.known_movement == {0.0, -1.0, 0.0}
    refute motion.on_ground
    assert motion.horizontal_collision

    # A rejected floor entry cannot erase an already accepted fall.
    move(client, %{top | y: 63.0}, 1)
    client = correction(client, pid, down)
    assert state(pid).player.motion.fall_distance == 1.0
    Client.send_packet(client, :play, "client_tick_end", <<>>)
    wait(fn -> state(pid).player.motion.known_movement == {0.0, 0.0, 0.0} end)

    # This is a client report even while airborne, not proof of solid support.
    Client.send_packet(client, :play, "move_player_status_only", <<3>>)
    wait(fn -> state(pid).player.motion.on_ground end)
    assert state(pid).player.y == 67.0
    assert state(pid).player.motion.fall_distance == 0.0

    move(client, %{top | y: 66.5}, 0)
    wait(fn -> state(pid).player.motion.fall_distance == 0.5 end)
    Client.send_packet(client, :play, "move_player_rot", <<12.0::float-32, 0.0::float-32, 0>>)
    wait(fn -> state(pid).player.yaw == 12.0 end)
    assert state(pid).player.motion.fall_distance == 0.5
    move(client, %{top | y: 66.6}, 0)
    wait(fn -> state(pid).player.y == 66.6 end)
    assert state(pid).player.motion.fall_distance == 0.0
    move(client, %{top | y: 66.4}, 0)
    wait(fn -> state(pid).player.y == 66.4 end)
    assert state(pid).player.motion.fall_distance > 0.0
    Client.send_packet(client, :play, "player_abilities", <<2>>)
    wait(fn -> state(pid).player.abilities.flying end)
    assert state(pid).player.motion.fall_distance == 0.0
  end

  test "pending geometry cannot accrue a fall, and relocation retires its context", ctx do
    {client, pid} = login(hd(ctx.names))
    top = %{ctx.pos | y: 68.0}
    :ok = Connection.teleport(pid, top)
    client = correction(client, pid, top)
    move(client, %{top | y: 67.0}, 0)
    wait(fn -> state(pid).player.y == 67.0 end)
    {:ok, {owner, _}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      move(client, %{top | y: 66.0}, 0)
      wait(fn -> state(pid).motion_job end)
      assert state(pid).player.motion.fall_distance == 1.0
      :ok = Connection.teleport(pid, top)
      assert state(pid).player.motion.fall_distance == 0.0
      _client = correction(client, pid, top)
      assert state(pid).player.y == 68.0
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end
  end

  test "disconnect and reconnect retain a midair fall without retaining old movement", ctx do
    name = hd(ctx.names)
    {client, pid} = login(name)
    top = %{ctx.pos | y: 69.0}
    :ok = Connection.teleport(pid, top)
    client = correction(client, pid, top)
    move(client, %{top | y: 67.75}, 0)
    wait(fn -> state(pid).player.y == 67.75 end)
    assert state(pid).player.motion.fall_distance == 1.25
    Client.close(client)
    wait(fn -> not Process.alive?(pid) end)
    uuid = Connection.offline_uuid(name)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == [] end)
    {_client, replacement} = login(name)
    assert state(replacement).player.motion.fall_distance == 1.25
    assert state(replacement).player.motion.known_movement == {0.0, 0.0, 0.0}
  end

  test "login restores native-clamped velocity after its teleport without stale observations",
       ctx do
    name = hd(ctx.names)
    uuid = Connection.offline_uuid(name)

    player =
      Map.merge(%{ctx.pos | y: 68.0}, %{
        game_mode: Valimc.GameMode.new(:creative),
        abilities: Valimc.PlayerAbilities.for_mode(:creative),
        motion: %Valimc.PlayerMotion{
          velocity: {0.3, -0.8, 12.0},
          physical_ground: true,
          settled: true,
          known_movement: {4.0, 2.0, 0.0},
          paths:
            Valimc.Physics.MovementPaths.record(
              %Valimc.Physics.MovementPaths{},
              {ctx.pos.x, 68.0, ctx.pos.z},
              {0.1, 0.0, 0.0},
              {0.1, 0.0, 0.0}
            ),
          stuck_multiplier: {0.25, 0.05000000074505806, 0.25},
          fall_distance: 1.5
        },
        environment: %Valimc.PlayerEnvironment{frozen_ticks: 27}
      })

    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(player, Inventory.new()))
    File.write!(PlayerStore.path(Valimc.config(:world_path), uuid), bytes)
    {^uuid, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    {body, _client} = Client.await(client, :play, "set_entity_motion")
    pid = owner(name)
    current = state(pid)
    assert {id, payload} = Wire.take_varint(body)
    assert id == current.player.entity_id
    assert {:ok, {x, y, z}} = PackedVelocity.decode(payload)
    assert abs(x - 0.3) < 0.0001 and abs(y + 0.8) < 0.0001 and z == 0.0
    assert current.player.motion.velocity == {0.3, -0.8, 0.0}
    assert current.player.motion.known_movement == {0.0, 0.0, 0.0}
    assert current.player.motion.paths.count == 0
    assert current.player.motion.stuck_multiplier == {0.0, 0.0, 0.0}
    refute current.player.motion.physical_ground or current.player.motion.settled
    assert current.player.motion.fall_distance == 1.5
    assert current.player.environment.frozen_ticks == 27
    refute current.teleport_pending or current.login_velocity_pending
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

  test "an authoritative mode change invalidates geometry prepared while admission waits", ctx do
    {client, pid} = login(hd(ctx.names))
    :ok = World.set_block({floor(ctx.pos.x) + 1, 64, floor(ctx.pos.z)}, 1)
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

      for holder <- holders, do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, holder)
      wait(fn -> state(pid).player.x == ctx.pos.x + 0.5 end)
      refute state(pid).teleport_pending
      assert state(pid).player.game_mode.current == :spectator
    after
      for holder <- holders,
          Process.alive?(holder),
          do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, holder)
    end
  end
end
