defmodule Valimc.DimensionTravelConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 180_000
  alias Valimc.{
    Connection,
    Dimension,
    Inventory,
    PlayerHealth,
    PlayerSnapshot,
    PlayerStore,
    Players
  }

  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Travel#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-travel-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    # Overworld and Nether regions of their own, away from other suites' keys.
    {rx, rz} = key = {121_000 + rem(nonce, 3_000) * 3, -743}
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for dx <- -1..1,
          dz <- -1..1,
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {rx + dx, rz + dz}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      # Every Nether and End owner is this suite's.
      elsewhere = [{{{:"$1", :_}, :"$2", :_}, [{:is_atom, :"$1"}], [:"$2"]}]

      for pid <- Registry.select(Valimc.RegionRegistry, elsewhere),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      for pid <- Registry.select(Valimc.ProtoRegistry, elsewhere),
          do: DynamicSupervisor.terminate_child(Valimc.ProtoSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      key: key,
      base: base,
      pose: pose,
      path: PlayerStore.path(base, uuid)
    }
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, left \\ 6000) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end

  defp seed(ctx) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.GameMode.new(:creative),
        abilities: Valimc.PlayerAbilities.for_mode(:creative),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{},
        health: %PlayerHealth{value: 13.0},
        last_death: nil,
        air_supply: 300
      })

    inventory = %Inventory{slots: %{36 => ItemStack.new("obsidian", 12)}}
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  # Login up to the login packet, which is returned with the client.
  defp join(ctx) do
    {_uuid, client} = Client.configure_session(Client.begin_login(ctx.name), ctx.name)
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {login, client} = Client.await(client, :play, "login")
    pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    on_exit(fn -> Client.close(client) end)
    {login, client, pid}
  end

  defp travel(pid, dimension, pose) do
    deadline = System.monotonic_time(:millisecond) + 5000
    pose = Map.put(pose, :dimension, dimension)
    assert {:ok, :ok} = GenServer.call(pid, {:command_op, {:teleport, pose}, deadline}, 6000)
  end

  defp context(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)

    case List.keyfind(dictionary, {Dimension, :current}, 0) do
      {_, dimension} -> dimension
      nil -> :overworld
    end
  end

  # `CommonPlayerSpawnInfo`: dimension type, level, hashed seed, modes, flags,
  # death location, portal cooldown, sea level.
  defp spawn_info(body) do
    {type, rest} = Wire.take_varint(body)
    {level, rest} = Wire.take_string(rest)
    <<_seed::64, rest::binary>> = rest
    {_mode, rest} = Wire.take_varint(rest)
    {_previous, rest} = Wire.take_varint(rest)
    <<_debug, flat, death, rest::binary>> = rest

    {death, rest} =
      if death == 1 do
        {dimension, rest} = Wire.take_string(rest)
        <<_position::64, rest::binary>> = rest
        {dimension, rest}
      else
        {nil, rest}
      end

    {cooldown, rest} = Wire.take_varint(rest)
    {sea, rest} = Wire.take_varint(rest)

    {%{type: type, level: level, flat: flat == 1, death: death, cooldown: cooldown, sea: sea},
     rest}
  end

  defp login_levels(<<_entity::32, _hardcore, body::binary>>) do
    {count, rest} = Wire.take_varint(body)

    {levels, rest} =
      Enum.map_reduce(1..count, rest, fn _, rest -> Wire.take_string(rest) end)

    {_max, rest} = Wire.take_varint(rest)
    {_view, rest} = Wire.take_varint(rest)
    {_simulation, rest} = Wire.take_varint(rest)
    <<_reduced, _death_screen, _limited, rest::binary>> = rest
    {info, <<_online, _secure>>} = spawn_info(rest)
    {Enum.sort(levels), info}
  end

  # Sections of a `level_chunk_with_light` body, and its sky light mask.
  defp chunk_sections(<<_cx::32, _cz::32, body::binary>>) do
    {maps, rest} = Wire.take_varint(body)

    rest =
      Enum.reduce(1..maps, rest, fn _, rest ->
        {_type, rest} = Wire.take_varint(rest)
        {longs, rest} = Wire.take_varint(rest)
        binary_part(rest, longs * 8, byte_size(rest) - longs * 8)
      end)

    {size, rest} = Wire.take_varint(rest)
    <<data::binary-size(^size), rest::binary>> = rest
    {_entities, rest} = Wire.take_varint(rest)
    {sky_mask, _} = Wire.take_varint(rest)
    {sections(data, 0), sky_mask}
  end

  defp sections(<<>>, count), do: count

  defp sections(<<_blocks::16, _fluids::16, bits, rest::binary>>, count) do
    rest = container(rest, bits, 4096, 8)
    <<biome_bits, rest::binary>> = rest
    sections(container(rest, biome_bits, 64, 3), count + 1)
  end

  defp container(rest, 0, _entries, _indirect), do: elem(Wire.take_varint(rest), 1)

  defp container(rest, bits, entries, indirect) do
    rest =
      if bits <= indirect do
        {length, rest} = Wire.take_varint(rest)
        Enum.reduce(1..length, rest, fn _, rest -> elem(Wire.take_varint(rest), 1) end)
      else
        rest
      end

    per = div(64, bits)
    longs = div(entries + per - 1, per)
    binary_part(rest, longs * 8, byte_size(rest) - longs * 8)
  end

  test "a player travels to the Nether and back, keeps its state and rejoins there", ctx do
    seed(ctx)
    {login, client, pid} = join(ctx)
    {levels, info} = login_levels(login)
    assert levels == ~w(minecraft:overworld minecraft:the_end minecraft:the_nether)
    assert info.level == "minecraft:overworld" and info.flat
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)

    nether = %{x: 8.5, y: 120.0, z: 8.5, yaw: 90.0, pitch: 0.0}
    travel(pid, :the_nether, nether)
    {respawn, client} = Client.await(client, :play, "respawn")
    {info, <<keep>>} = spawn_info(respawn)
    assert keep == 3
    assert info.type == Dimension.facts(:the_nether).type_id
    assert info.level == "minecraft:the_nether" and not info.flat and info.sea == 32

    {position, client} = Client.await(client, :play, "player_position")
    {_, <<x::float-64, y::float-64, z::float-64, _::binary>>} = Wire.take_varint(position)
    assert {x, y, z} == {8.5, 120.0, 8.5}
    client = Client.auto_reply(client, :play, "player_position", position)
    assert context(pid) == :the_nether
    assert state(pid).player.dimension == :the_nether
    assert state(pid).player.health.value == 13.0
    assert state(pid).inventory.slots[36] == ItemStack.new("obsidian", 12)

    # The client's level is the Nether's 16 sections, without sky light.
    {chunk, client} = Client.await(client, :play, "level_chunk_with_light", 3000)
    assert chunk_sections(chunk) == {16, 0}
    assert [_] = Registry.lookup(Valimc.RegionRegistry, {:the_nether, {0, 0}})
    assert File.dir?(Path.join(ctx.base, "dimensions/minecraft/the_nether"))

    # The arrival was saved before the switch.
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.dimension == :the_nether and saved.pose.x == 8.5

    # A reconnect rejoins in the Nether.
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {login, client, pid} = join(ctx)
    {_levels, info} = login_levels(login)
    assert info.level == "minecraft:the_nether"
    assert info.type == Dimension.facts(:the_nether).type_id
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    assert context(pid) == :the_nether
    {chunk, client} = Client.await(client, :play, "level_chunk_with_light", 3000)
    assert chunk_sections(chunk) == {16, 0}

    # And back to the overworld.
    travel(pid, :overworld, ctx.pose)
    {respawn, client} = Client.await(client, :play, "respawn")
    {info, <<3>>} = spawn_info(respawn)
    assert info.level == "minecraft:overworld" and info.flat
    {position, client} = Client.await(client, :play, "player_position")
    _client = Client.auto_reply(client, :play, "player_position", position)
    assert context(pid) == :overworld
    wait(fn -> match?({:ok, %{dimension: :overworld}}, Players.get(pid)) end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert Map.get(saved, :dimension, :overworld) == :overworld
  end

  defp enter(ctx, name \\ nil) do
    ctx = if name, do: %{ctx | name: name}, else: ctx
    {_login, client, pid} = join(ctx)
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    {client, pid}
  end

  defp arrive(client, pid) do
    {respawn, client} = Client.await(client, :play, "respawn")
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    wait(fn -> not state(pid).teleport_pending end)
    {respawn, client}
  end

  test "a death in the Nether respawns in the overworld with a Nether death location", ctx do
    seed(ctx)
    {client, pid} = enter(ctx)
    travel(pid, :the_nether, %{x: 8.5, y: 120.0, z: 8.5, yaw: 0.0, pitch: 0.0})
    {_respawn, client} = arrive(client, pid)
    deadline = System.monotonic_time(:millisecond) + 5000
    GenServer.call(pid, {:command_op, :kill, deadline}, 6000)
    wait(fn -> state(pid).life_stage == :dead end)
    Client.send_packet(client, :play, "client_command", <<0>>)
    {respawn, _client} = Client.await(client, :play, "respawn")
    {info, <<0>>} = spawn_info(respawn)
    assert info.level == "minecraft:overworld"
    assert info.death == "minecraft:the_nether"
    wait(fn -> state(pid).life_stage == :alive end)
    assert context(pid) == :overworld
    assert state(pid).player.dimension == :overworld
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.death_dimension == :the_nether and saved.dimension == :overworld
  end

  test "players see each other only in the same dimension", ctx do
    seed(ctx)
    other = ctx.name <> "b"
    {:ok, bytes} = File.read(ctx.path)
    other_uuid = Connection.offline_uuid(other)
    {:ok, snapshot} = PlayerSnapshot.decode(bytes, ctx.uuid)
    {:ok, other_bytes} = PlayerSnapshot.encode(other_uuid, snapshot)
    File.write!(PlayerStore.path(ctx.base, other_uuid), other_bytes)

    on_exit(fn ->
      for p <- Players.all(),
          p.name == other,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)
    end)

    {_client_a, a} = enter(ctx)
    {client_b, b} = enter(ctx, other)
    wait(fn -> Map.has_key?(state(a).peers, b) and Map.has_key?(state(b).peers, a) end)

    # The same coordinates in the Nether are another world.
    travel(b, :the_nether, ctx.pose)
    {_respawn, client_b} = arrive(client_b, b)
    wait(fn -> not Map.has_key?(state(a).peers, b) end)
    Process.sleep(300)
    refute Map.has_key?(state(b).peers, a)
    refute Map.has_key?(state(a).peers, b)

    travel(b, :overworld, ctx.pose)
    {_respawn, _client_b} = arrive(client_b, b)
    wait(fn -> Map.has_key?(state(a).peers, b) and Map.has_key?(state(b).peers, a) end)
  end
end
