defmodule Valimc.MovementFoodConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, Inventory, PlayerFood, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Travel#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-travel-food-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {108_000 + rem(nonce, 10_000), 988}
    {rx, rz} = key
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

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

    %{name: name, uuid: uuid, pose: pose, key: key, path: PlayerStore.path(base, uuid)}
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

  defp seed(ctx, opts \\ []) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{},
        health: %Valimc.PlayerHealth{},
        last_death: nil,
        air_supply: 300,
        food: Keyword.get(opts, :food, %PlayerFood{})
      })

    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp park(pid) do
    :sys.replace_state(pid, fn s ->
      %{
        s
        | simulation_clock: %{
            s.simulation_clock
            | token: {s.simulation_clock.epoch, make_ref()},
              deadline: System.monotonic_time(:millisecond) + 60_000
          }
      }
    end)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    {pid, _} = Enum.find(:ets.tab2list(Players), fn {_, p} -> p.name == ctx.name end)
    park(pid)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp move(client, position, flags \\ 1) do
    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<position.x::float-64, position.y::float-64, position.z::float-64, flags>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])
  end

  defp moved(pid, position) do
    wait(fn ->
      s = state(pid)

      Map.take(s.player, [:x, :y, :z]) == Map.take(position, [:x, :y, :z]) and s.motion_job == nil and
        s.motion_pending == nil
    end)
  end

  defp command(client, pid, sprinting) do
    Client.send_packet(
      client,
      :play,
      "player_command",
      Wire.varint(0) <> Wire.varint(if(sprinting, do: 1, else: 2)) <> Wire.varint(0)
    )

    wait(fn -> Bitwise.band(state(pid).player.input.shared_flags, 8) != 0 == sprinting end)
  end

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await(client, :play, "system_chat")
    client
  end

  defp tick(pid) do
    before =
      :sys.replace_state(pid, fn s ->
        %{
          s
          | simulation_clock: %{
              s.simulation_clock
              | deadline: System.monotonic_time(:millisecond)
            }
        }
      end)

    send(pid, {:player_tick, before.simulation_clock.token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick + 1
    park(pid)
  end

  test "accepted sprint consumes the native amount once, drains food on tick and survives reconnect",
       ctx do
    food = %PlayerFood{saturation: 0.0, exhaustion: 3.9375}
    seed(ctx, food: food)
    {client, pid} = login(ctx)
    command(client, pid, true)
    target = %{ctx.pose | x: ctx.pose.x + 1.0}
    move(client, target)
    moved(pid, target)
    exhausted = PlayerFood.exhaust(food, 0.10000000149011612)
    assert state(pid).player.food == exhausted
    tick(pid)
    assert state(pid).player.food.level == 19 and state(pid).player.food.saturation == 0.0
    {<<20.0::float-32, rest::binary>>, client} = Client.await(client, :play, "set_health")
    assert {19, <<+0.0::float-32>>} = Wire.take_varint(rest)
    saved_food = state(pid).player.food
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == saved_food and saved.inventory.slots[36] == ItemStack.new("stone", 7)
    assert saved.transfer_sequence == 0 and saved.outbox == nil
    {_client, owner} = login(ctx)
    assert state(owner).player.food == saved_food
  end

  test "walking and scratch/held-jump ticks spend nothing; only an accepted grounded jump spends",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    ground = %{ctx.pose | x: ctx.pose.x + 0.2}
    move(client, ground)
    moved(pid, ground)
    assert state(pid).player.food == %PlayerFood{}
    Client.send_packet(client, :play, "player_input", <<16>>)
    _ = barrier(client)
    tick(pid)
    assert state(pid).player.food == %PlayerFood{}
    air = %{ground | y: 64.42}
    move(client, air, 0)
    moved(pid, air)
    one = PlayerFood.exhaust(%PlayerFood{}, 0.05000000074505806)
    assert state(pid).player.food == one
    higher = %{air | y: 64.6}
    move(client, higher, 0)
    moved(pid, higher)
    assert state(pid).player.food == one
    move(client, ground)
    moved(pid, ground)
    command(client, pid, true)
    move(client, air, 0)
    moved(pid, air)
    assert state(pid).player.food == PlayerFood.exhaust(one, 0.20000000298023224)
  end

  for {kind, states} <- [
        body_water: [{64, 89}],
        underwater: [{64, 89}, {65, 89}, {66, 89}],
        bubbles: [{64, 89}, {65, 18651}, {66, 18651}]
      ] do
    test "native #{kind} travel uses the selected body/eyes and keeps bubble air semantics",
         ctx do
      seed(ctx)

      for {y, id} <- unquote(states),
          do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, id)

      {client, pid} = login(ctx)
      target = %{ctx.pose | y: ctx.pose.y + 0.1}
      move(client, target, 0)
      moved(pid, target)
      expected = if unquote(kind) == :body_water, do: 0.0, else: 0.0009999999310821295
      assert state(pid).player.food.exhaustion == expected

      if unquote(kind) == :bubbles do
        tick(pid)
        assert state(pid).player.air_supply == 300
      end
    end
  end

  for mode <- [:creative, :spectator] do
    test "#{mode} current abilities prevent sprint and jump exhaustion", ctx do
      seed(ctx, mode: unquote(mode))
      {client, pid} = login(ctx)
      command(client, pid, true)
      ground = %{ctx.pose | x: ctx.pose.x + 0.1}
      move(client, ground)
      moved(pid, ground)
      air = %{ground | y: 64.42}
      move(client, air, 0)
      moved(pid, air)
      assert state(pid).player.food == %PlayerFood{}
    end
  end

  test "selected swimming takes precedence over the sprint flag", ctx do
    seed(ctx)
    for y <- 64..66, do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 89)
    {client, pid} = login(ctx)
    command(client, pid, true)
    target = %{ctx.pose | y: 64.1}
    move(client, target, 0)
    moved(pid, target)
    assert state(pid).player.motion.swimming
    assert state(pid).player.food.exhaustion == 0.0009999999310821295
  end

  test "fresh ladder contact suppresses grounded sprint cost until the ladder is removed", ctx do
    seed(ctx)
    pos = {floor(ctx.pose.x), 64, floor(ctx.pose.z)}
    :ok = World.set_block(pos, 7308)
    {client, pid} = login(ctx)
    command(client, pid, true)
    target = %{ctx.pose | x: ctx.pose.x + 0.1}
    move(client, target)
    moved(pid, target)
    assert state(pid).player.food == %PlayerFood{}
    :ok = World.set_block(pos, 0)
    next = %{target | x: target.x + 0.1}
    move(client, next)
    moved(pid, next)
    assert state(pid).player.food == PlayerFood.exhaust(%PlayerFood{}, 0.009999999776482582)
  end

  test "blocked movement retains wire ordering before a later stop-sprinting command", ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    command(client, pid, true)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :sys.suspend(region)

    try do
      target = %{ctx.pose | x: ctx.pose.x + 0.2}
      move(client, target)
      _old = wait(fn -> state(pid).motion_job end)
      Client.send_packet(client, :play, "player_command", <<0, 2, 0>>)
      assert state(pid).player.food == %PlayerFood{}
      :sys.resume(region)
      moved(pid, target)
      wait(fn -> Bitwise.band(state(pid).player.input.shared_flags, 8) == 0 end)
      expected = PlayerFood.exhaust(%PlayerFood{}, 0.019999999552965164)
      assert state(pid).player.food == expected
      next = %{target | x: target.x + 0.2}
      move(client, next)
      moved(pid, next)
      assert state(pid).player.food == expected
    after
      if Process.alive?(region), do: :sys.resume(region)
    end
  end

  test "speed and collision corrections and retired geometry cannot spend exhaustion", ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    command(client, pid, true)
    move(client, %{ctx.pose | x: ctx.pose.x + 20})
    {body, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)
    assert state(pid).player.food == %PlayerFood{}
    :ok = World.set_block({floor(ctx.pose.x) + 1, 64, floor(ctx.pose.z)}, 1)
    move(client, %{ctx.pose | x: ctx.pose.x + 0.4})
    {body, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)
    assert state(pid).player.food == %PlayerFood{}
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :sys.suspend(region)

    try do
      move(client, %{ctx.pose | z: ctx.pose.z + 0.1})
      job = wait(fn -> state(pid).motion_job end)
      :ok = Connection.teleport(pid, %{ctx.pose | z: ctx.pose.z + 0.2})
      send(pid, {job.task.ref, {:ok, %{accepted: true, exhaustion: %{jump: 40.0, travel: 40.0}}}})
      assert state(pid).player.food == %PlayerFood{}
      assert Process.alive?(pid)
    after
      if Process.alive?(region), do: :sys.resume(region)
    end
  end

  test "food ticks during blocked geometry are retained when the movement result commits", ctx do
    food = %PlayerFood{saturation: 0.0, exhaustion: 4.125}
    seed(ctx, food: food)
    {client, pid} = login(ctx)
    command(client, pid, true)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :sys.suspend(region)

    try do
      target = %{ctx.pose | x: ctx.pose.x + 0.2}
      move(client, target)
      _job = wait(fn -> state(pid).motion_job end)
      tick(pid)
      spent = %PlayerFood{level: 19, saturation: 0.0, exhaustion: 0.125}
      assert state(pid).player.food == spent
      :sys.resume(region)
      moved(pid, target)
      assert state(pid).player.food == PlayerFood.exhaust(spent, 0.019999999552965164)
    after
      if Process.alive?(region), do: :sys.resume(region)
    end
  end
end
