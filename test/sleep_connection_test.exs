defmodule Valimc.SleepConnectionTest do
  @moduledoc """
  Beds, sleep and respawn points through real sessions (VMC-040a): a player
  lies down at night unless a monster is near, its bed becomes its respawn
  point, it gets up when it leaves the bed or is hurt; the night skips only
  when the share of players sleeps; a death respawns at the bed and, without
  it, at the world spawn; glowstone charges an anchor that explodes outside
  the Nether, and a bed explodes in the Nether. The rules themselves are
  `check_sleep.exs`'s.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag :slow
  @moduletag timeout: 180_000
  alias Valimc.Data.Blocks
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.PlayerList
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, UseItemOn}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.{Clock, Dimension, Region}

  setup do
    nonce = System.unique_integer([:positive])
    name = "Sleep#{nonce}"
    base = Path.join(System.tmp_dir!(), "valimc-sleep-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    {rx, rz} = key = {131_000 + rem(nonce, 3_000) * 3, -811}
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
    day = Clock.snapshot().clocks["minecraft:overworld"].total_ticks

    on_exit(fn ->
      for p <- PlayerList.all(),
          String.starts_with?(p.name, name),
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      :ok = Clock.configure({"minecraft:overworld", :ticks, day})
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_dimensions()
      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{name: name, base: base, key: key, pose: pose}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)
  defp wait(fun), do: Valimc.TestWait.until(fun)

  # A survival player at `pose` holding `slots`, logged in with a parked clock.
  defp enter(ctx, name, slots \\ %{}, pose \\ nil) do
    uuid = Valimc.Data.UUID.offline(name)

    player =
      Map.merge(pose || ctx.pose, %{
        living: %Valimc.Living{},
        game_mode: Valimc.Player.GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        motion: %Valimc.Player.Motion{},
        last_death: nil
      })

    path = Valimc.Player.Storage.path(ctx.base, uuid)
    {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(player, %Inventory{slots: slots}))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    {_uuid, client} = Client.configure_session(Client.begin_login(name), name)
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_login, client} = Client.await(client, :play, "login")
    pid = wait(fn -> Enum.find(PlayerList.all(), &(&1.name == name)) end).pid
    on_exit(fn -> Client.close(client) end)
    Valimc.TestPlayer.park(pid)
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    {client, pid}
  end

  # A bed whose foot is two blocks east of `pose`, its head three, facing east.
  defp bed(%{x: x, y: y, z: z}, name \\ "red_bed") do
    foot = {floor(x) + 2, floor(y), floor(z)}
    {fx, y, fz} = foot
    head = {fx + 1, y, fz}
    props = %{"facing" => "east", "occupied" => "false"}
    :ok = Valimc.TestBlocks.set(foot, Blocks.state(name, Map.put(props, "part", "foot")))
    :ok = Valimc.TestBlocks.set(head, Blocks.state(name, Map.put(props, "part", "head")))
    {foot, head}
  end

  defp use(client, position, sequence, hand \\ :main) do
    {:ok, bytes} =
      UseItemOn.encode(%{
        hand: hand,
        position: position,
        face: 1,
        cursor: {0.5, 0.5, 0.5},
        inside: false,
        border: false,
        sequence: sequence
      })

    Client.send_packet(client, :play, "use_item_on", bytes)
  end

  # Confirm the teleports lying down and getting up send, up to the latest.
  defp settle(client, pid) do
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    {id, _} = Valimc.Protocol.Wire.take_varint(position)

    if id == state(pid).teleport do
      wait(fn -> not state(pid).teleport_pending end)
      client
    else
      settle(client, pid)
    end
  end

  defp prop(position, key),
    do: Map.new(Blocks.properties(Valimc.TestBlocks.get(position)))[key]

  defp name(position), do: Blocks.name(Blocks.block_id(Valimc.TestBlocks.get(position)))

  defp tick(pid, n), do: for(_ <- 1..n, do: Valimc.TestPlayer.tick(pid))

  defp night, do: :ok = Clock.configure({"minecraft:overworld", :ticks, 18_000})

  defp day_ticks, do: Clock.snapshot().clocks["minecraft:overworld"].total_ticks

  # A death and a respawn: the packets before the respawn packet, and the client.
  defp respawn(client, pid) do
    deadline = System.monotonic_time(:millisecond) + 5000
    GenServer.call(pid, {:command_op, :kill, deadline}, 6000)
    wait(fn -> state(pid).life_stage == :dead end)
    Client.send_packet(client, :play, "client_command", <<0>>)
    {before, client} = until_respawn(client, [])
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    wait(fn -> state(pid).life_stage == :alive and not state(pid).teleport_pending end)
    {before, client}
  end

  defp until_respawn(client, seen) do
    {id, body, client} = Client.read(client)
    name = Valimc.Protocol.Data.name(:play, :clientbound, id)

    if name == "respawn",
      do: {Enum.reverse(seen), client},
      else: until_respawn(Client.auto_reply(client, :play, name, body), [{name, body} | seen])
  end

  test "a player sleeps at night unless a monster is near, sets its spawn and gets up", ctx do
    night()
    {client, pid} = enter(ctx, ctx.name)
    {foot, head} = bed(ctx.pose)

    # A zombie beside the bed keeps the player awake; the bed still sets its spawn.
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, zombie} = Body.new("minecraft:zombie")
    zombie = put_in(zombie.mob.no_ai, true)
    uuid = <<40::128>>

    :ok =
      Region.drop_items(owner, [
        Store.body_record(zombie, uuid, {ctx.pose.x + 6.0, 64.0, ctx.pose.z})
      ])

    wait(fn -> Enum.any?(Valimc.World.bodies(:overworld), &(elem(&1, 1).uuid == uuid)) end)
    use(client, foot, 1)
    wait(fn -> state(pid).player.respawn != nil end)
    assert state(pid).player.respawn.position == head
    refute state(pid).player.sleeping

    # A killed zombie lies dying: it keeps nobody awake.
    {:ok, 1} = Region.kill_entities(owner, [uuid])
    use(client, foot, 2)
    wait(fn -> state(pid).player.sleeping != nil end)
    player = state(pid).player
    assert player.pose == :sleeping and player.time_since_rest == 0
    assert {player.x, player.y} == {elem(head, 0) + 0.5, 64.6875}
    assert prop(head, "occupied") == "true" and prop(foot, "occupied") == "true"

    # Leaving the bed frees it and stands the player up beside it.
    Client.send_packet(client, :play, "player_command", <<0, 0, 0>>)
    wait(fn -> state(pid).player.sleeping == nil end)
    assert state(pid).player.pose == :standing
    assert prop(head, "occupied") == "false" and prop(foot, "occupied") == "false"

    # A hurt sleeper gets up too.
    client = settle(client, pid)
    use(client, foot, 3)
    wait(fn -> state(pid).player.sleeping != nil end)
    {:ok, _} = Valimc.TestConn.fall_damage(pid, 1.0)
    assert state(pid).player.sleeping == nil
    tick(pid, 3)
    assert state(pid).player.time_since_rest == 3
  end

  test "one of two players asleep keeps the night; both asleep skip to morning", ctx do
    night()
    {client_a, a} = enter(ctx, ctx.name <> "a")
    other = %{ctx.pose | z: ctx.pose.z + 4.0}
    {client_b, b} = enter(ctx, ctx.name <> "b", %{}, other)
    {foot_a, _} = bed(ctx.pose)
    {foot_b, _} = bed(other)

    use(client_a, foot_a, 1)
    wait(fn -> state(a).player.sleeping != nil end)
    tick(a, 110)
    Process.sleep(300)
    assert rem(day_ticks(), 24_000) > 12_000
    assert state(a).player.sleeping != nil

    use(client_b, foot_b, 1)
    wait(fn -> state(b).player.sleeping != nil end)
    tick(b, 100)
    wait(fn -> rem(day_ticks(), 24_000) < 1_000 end)
    wait(fn -> state(a).player.sleeping == nil and state(b).player.sleeping == nil end)
  end

  test "a death respawns at the bed, and without it at the world spawn", ctx do
    {client, pid} = enter(ctx, ctx.name)
    {foot, head} = bed(ctx.pose)
    # By day the bed only sets the spawn.
    :ok = Clock.configure({"minecraft:overworld", :ticks, 6_000})
    use(client, foot, 1)
    wait(fn -> state(pid).player.respawn != nil end)
    refute state(pid).player.sleeping

    {_before, client} = respawn(client, pid)
    player = state(pid).player
    {hx, _, hz} = head
    assert abs(player.x - (hx + 0.5)) <= 2.5 and abs(player.z - (hz + 0.5)) <= 2.5
    assert state(pid).player.respawn.position == head

    :ok = Valimc.TestBlocks.set(head, Blocks.default_state("air"))
    :ok = Valimc.TestBlocks.set(foot, Blocks.default_state("air"))
    {before, _client} = respawn(client, pid)
    assert {"game_event", <<0, 0.0::float-32>>} in before
    assert state(pid).player.respawn == nil
  end

  test "glowstone charges an anchor, which explodes outside the Nether", ctx do
    slots = %{36 => ItemStack.new("glowstone", 2)}
    {client, pid} = enter(ctx, ctx.name, slots)
    anchor = {floor(ctx.pose.x) + 3, 64, floor(ctx.pose.z)}
    :ok = Valimc.TestBlocks.set(anchor, Blocks.default_state("respawn_anchor"))

    use(client, anchor, 1)
    wait(fn -> prop(anchor, "charges") == "1" end)
    assert state(pid).inventory.slots[36].count == 1

    # An empty hand uses the charged anchor: in the overworld it blows up.
    Client.send_packet(client, :play, "set_carried_item", <<1::16>>)
    wait(fn -> state(pid).inventory.selected == 1 end)
    use(client, anchor, 2)
    {_explode, _client} = Client.await(client, :play, "explode", 2_000)
    assert name(anchor) == "air"
    wait(fn -> Valimc.TestPlayer.living(pid).health.value < 20.0 end)
  end

  test "a bed explodes in the Nether", ctx do
    {client, pid} = enter(ctx, ctx.name)
    nether = %{ctx.pose | y: 100.0}
    deadline = System.monotonic_time(:millisecond) + 5000
    pose = Map.put(nether, :dimension, :the_nether)
    assert {:ok, :ok} = GenServer.call(pid, {:command_op, {:teleport, pose}, deadline}, 6000)
    {_respawn, client} = Client.await(client, :play, "respawn")
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    wait(fn -> not state(pid).teleport_pending end)

    Dimension.within(:the_nether, fn ->
      {foot, head} = bed(nether)
      use(client, foot, 1)
      {_explode, _client} = Client.await(client, :play, "explode", 2_000)
      assert name(head) == "air" and name(foot) == "air"
    end)
  end
end
