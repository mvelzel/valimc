defmodule Valimc.PlayerLandingConnectionTest do
  use ExUnit.Case, async: false

  alias Valimc.{
    Connection,
    Inventory,
    PlayerHealth,
    PlayerMotion,
    PlayerSnapshot,
    PlayerStore,
    Players,
    World
  }

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Land#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-landing-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {62_000 + rem(nonce, 10_000), 980}
    {rx, rz} = key
    pose = %{x: rx * 128 + 40.5, y: 72.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      base: base,
      key: key,
      pose: pose,
      path: PlayerStore.path(base, uuid)
    }
  end

  defp state(pid), do: :sys.get_state(pid)

  defp wait(fun, left \\ 400) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        y: Keyword.get(opts, :y, ctx.pose.y),
        health: %PlayerHealth{value: Keyword.get(opts, :health, 20.0)},
        motion: %PlayerMotion{fall_distance: Keyword.get(opts, :distance, 0.0)},
        environment: %Valimc.PlayerEnvironment{},
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        last_death: nil
      })

    inventory = Keyword.get(opts, :inventory, %Inventory{})
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp move(client, pid, target, flags) do
    p = state(pid).player

    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<p.x::float-64, target::float-64, p.z::float-64, flags>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])
  end

  defp fall(client, pid, bottom) do
    p = state(pid).player
    target = max(bottom, p.y - 2.0)
    move(client, pid, target, if(target == bottom, do: 1, else: 0))
    wait(fn -> state(pid).player.y == target and state(pid).motion_job == nil end)
    if target != bottom, do: fall(client, pid, bottom)
    :ok
  end

  for {distance, damage} <- [{3.5, 0.0}, {4.0, 1.0}, {8.0, 5.0}] do
    test "accepted #{distance}-block fall applies #{damage} damage once and retains it on reconnect",
         ctx do
      seed(ctx,
        y: 64.0 + unquote(distance),
        inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
      )

      {client, pid} = login(ctx)
      fall(client, pid, 64.0)
      assert state(pid).player.health.value == 20.0 - unquote(damage)
      assert state(pid).player.motion.fall_distance == 0.0

      client =
        if unquote(damage) > 0 do
          {body, client} = Client.await(client, :play, "damage_event")
          {entity, body} = Wire.take_varint(body)
          {source, <<0, 0, 0>>} = Wire.take_varint(body)
          assert entity == state(pid).player.entity_id
          assert source == Data.registry_id("minecraft:damage_type", "minecraft:fall")
          {<<health::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
          assert health == 20.0 - unquote(damage)
          client
        else
          client
        end

      Client.send_packet(client, :play, "move_player_status_only", <<1>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await(client, :play, "system_chat")
      assert state(pid).player.health.value == 20.0 - unquote(damage)
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.health.value == 20.0 - unquote(damage)
      {second, owner} = login(ctx)
      assert state(owner).player.health.value == saved.health.value
      assert Enum.at(second.inventory.items, 36) == ItemStack.new("stone", 7)
      assert saved.transfer_sequence == 0 and saved.outbox == nil
    end
  end

  for {id, bottom, damage} <- [
        {2257, 63.5625, 1.0},
        {14741, 64.0, 1.0},
        {25173, 63.9375, 1.0},
        {14379, 64.0, 0.0}
      ] do
    test "live landing state #{id} uses its native distance/multiplier rule", ctx do
      seed(ctx, y: unquote(bottom) + 8.0)
      assert :ok = World.set_block({floor(ctx.pose.x), 63, floor(ctx.pose.z)}, unquote(id))
      {client, pid} = login(ctx)
      fall(client, pid, unquote(bottom))
      assert state(pid).player.health.value == 20.0 - unquote(damage)
      assert state(pid).player.motion.fall_distance == 0.0
    end
  end

  test "a ground-only report is sampled once instead of silently erasing saved fall distance",
       ctx do
    seed(ctx, y: 64.0, distance: 4.0)
    {client, pid} = login(ctx)
    Client.send_packet(client, :play, "move_player_status_only", <<1>>)
    wait(fn -> state(pid).player.health.value == 19.0 end)
    Client.send_packet(client, :play, "move_player_status_only", <<1>>)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(client, :play, "system_chat")
    assert state(pid).player.motion.fall_distance == 0.0
    assert state(pid).player.health.value == 19.0
  end

  test "scratch collision cannot cause damage; rejected or retired geometry cannot apply a landing",
       ctx do
    seed(ctx, y: 65.0, distance: 8.0)
    {client, pid} = login(ctx)
    assert :ok = Connection.set_velocity(pid, {0.0, -2.0, 0.0})
    wait(fn -> state(pid).player.motion.physical_ground end)
    assert state(pid).player.health.value == 20.0 and state(pid).player.y == 65.0
    move(client, pid, 63.0, 1)
    {body, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)

    assert state(pid).player.health.value == 20.0 and
             state(pid).player.motion.fall_distance == 8.0

    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :sys.suspend(region)

    try do
      move(client, pid, 64.0, 1)
      job = wait(fn -> state(pid).motion_job end)
      assert :ok = Connection.teleport(pid, %{ctx.pose | y: 80.0})

      send(
        pid,
        {job.task.ref,
         {:ok, %{accepted: true, landing: %{distance: 100, multiplier: 1, source: :fall}}}}
      )

      assert state(pid).player.health.value == 20.0 and state(pid).player.y == 80.0
    after
      :sys.resume(region)
    end
  end

  for mode <- [:creative, :spectator] do
    test "#{mode} stays immune to accepted landing damage", ctx do
      seed(ctx, mode: unquote(mode))
      {client, pid} = login(ctx)
      fall(client, pid, 64.0)
      assert state(pid).player.health.value == 20.0
      assert state(pid).life_stage == :alive
    end
  end

  test "water at the accepted destination prevents a restored fall from causing damage", ctx do
    seed(ctx, y: 64.5, distance: 20.0)
    assert :ok = World.set_block({floor(ctx.pose.x), 64, floor(ctx.pose.z)}, 89)
    {client, pid} = login(ctx)
    fall(client, pid, 64.0)
    assert state(pid).player.health.value == 20.0
    assert state(pid).player.motion.fall_distance == 0.0
  end

  for {id, damage} <- [{33570, 0.0}, {33571, 3.0}] do
    test "dripstone state #{id} composes water contact with its distance/source rule", ctx do
      seed(ctx, y: 65.6875)
      assert :ok = World.set_block({floor(ctx.pose.x), 63, floor(ctx.pose.z)}, unquote(id))
      {client, pid} = login(ctx)
      fall(client, pid, 63.6875)
      assert state(pid).player.health.value == 20.0 - unquote(damage)

      if unquote(damage) > 0 do
        {body, _} = Client.await(client, :play, "damage_event")
        {_, rest} = Wire.take_varint(body)
        {source, <<0, 0, 0>>} = Wire.take_varint(rest)
        assert source == Data.registry_id("minecraft:damage_type", "minecraft:stalagmite")
      end
    end
  end

  test "an admitted web contact clears a restored fall before the subsequent ordinary landing",
       ctx do
    seed(ctx, y: 65.0, distance: 20.0)
    pos = {floor(ctx.pose.x), 65, floor(ctx.pose.z)}
    assert :ok = World.set_block(pos, 2362)
    {client, pid} = login(ctx)
    wait(fn -> state(pid).player.motion.fall_distance == 0.0 end)
    assert :ok = World.set_block(pos, 0)
    fall(client, pid, 64.0)
    assert state(pid).player.health.value == 20.0
    assert state(pid).player.motion.fall_distance == 0.0
  end

  test "a fatal accepted landing runs durable multi-batch death and actual respawn protocol",
       ctx do
    inventory = %Inventory{slots: Map.new(36..43, &{&1, ItemStack.new("stone", &1 - 35)})}
    seed(ctx, health: 3.0, inventory: inventory)
    {client, pid} = login(ctx)
    fall(client, pid, 64.0)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    wait(fn -> state(pid).life_stage == :dead end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.transfer_sequence == 2 and saved.outbox == nil
    assert saved.inventory.slots == %{}
    assert map_size(World.item_snapshot(ctx.key)) == 8
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {<<20.0::float-32, _::binary>>, _} = Client.await(client, :play, "set_health")
    assert state(pid).life_stage == :alive and state(pid).inventory.slots == %{}
    assert state(pid).player.motion.fall_distance == 0.0
  end
end
