defmodule Valimc.PortalConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 240_000
  alias Valimc.{
    Connection,
    Dimension,
    Inventory,
    PlayerHealth,
    PlayerSnapshot,
    PlayerStore,
    Players,
    World
  }

  alias Valimc.Portal.Blocks
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.Directory

  setup do
    nonce = System.unique_integer([:positive])
    name = "Portal#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-portal-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    # An overworld region of its own; its Nether counterpart is an eighth of it.
    {rx, rz} = key = {64 + rem(nonce, 200) * 2, 40}
    origin = {rx * 128 + 40, 64, rz * 128 + 40}

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for dx <- -2..2,
          dz <- -2..2,
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {rx + dx, rz + dz}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

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
      origin: origin,
      path: PlayerStore.path(base, uuid)
    }
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, left \\ 12_000) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end

  defp seed(ctx, mode) do
    {x, y, z} = ctx.origin

    player = %{
      x: x + 3.5,
      y: y * 1.0,
      z: z + 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(mode),
      abilities: Valimc.PlayerAbilities.for_mode(mode),
      motion: %Valimc.PlayerMotion{},
      environment: %Valimc.PlayerEnvironment{},
      health: %PlayerHealth{},
      last_death: nil,
      air_supply: 300
    }

    inventory = %Inventory{slots: %{36 => ItemStack.new("flint_and_steel", 1)}}
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp enter(ctx) do
    {_, client} = Client.login(ctx.name)
    pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  # An obsidian frame with a 2 × 3 opening from `{x, y, z}` along X.
  defp frame({x, y, z}) do
    for dx <- -1..2, dy <- -1..3, dx in [-1, 2] or dy in [-1, 3], into: %{} do
      {{x + dx, y + dy, z}, Blocks.obsidian()}
    end
  end

  # Owners still generating answer late; the portal commits retry them.
  defp set(edits), do: :ok = Valimc.Portal.Access.commit(Map.to_list(edits))

  # The destination's regions a lit or opened portal admits ahead of the player.
  defp warmed?(kind, position) do
    {dimension, area} = Valimc.Portal.Warm.area(kind, position)

    Dimension.within(dimension, fn ->
      Enum.all?(Valimc.Portal.Warm.regions(area), &Directory.lookup/1)
    end)
  end

  defp blocks(positions, dimension \\ :overworld) do
    Dimension.within(dimension, fn ->
      read = Valimc.Portal.Access.reader()
      Map.new(positions, &{&1, read.(&1)})
    end)
  end

  defp move(client, pid, {x, y, z}) do
    deadline = System.monotonic_time(:millisecond) + 2000
    :ok = GenServer.call(pid, {:teleport, %{x: x, y: y, z: z, yaw: 0.0, pitch: 0.0}, deadline})
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    wait(fn -> not state(pid).teleport_pending end)
    client
  end

  defp arrive(client, pid) do
    {respawn, client} = Client.await(client, :play, "respawn", 2000)
    {_type, rest} = Wire.take_varint(respawn)
    {level, _} = Wire.take_string(rest)
    {position, client} = Client.await(client, :play, "player_position")
    {_, <<x::float-64, y::float-64, z::float-64, _::binary>>} = Wire.take_varint(position)
    client = Client.auto_reply(client, :play, "player_position", position)
    wait(fn -> not state(pid).teleport_pending end)
    {level, {x, y, z}, client}
  end

  test "a lit portal leads to a new Nether portal and back to itself; a broken frame puts it out",
       ctx do
    seed(ctx, :creative)
    {x, y, z} = bottom = ctx.origin
    set(frame(bottom))
    {client, pid} = enter(ctx)

    # Flint and steel on the frame's bottom, inside: the portal opens.
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(0),
      Wire.position({x, y - 1, z}),
      <<1, 0.5::float-32, 1.0::float-32, 0.5::float-32, 0, 0, 7>>
    ])

    opening = for dx <- 0..1, dy <- 0..2, do: {x + dx, y + dy, z}
    wait(fn -> Enum.all?(blocks(opening), fn {_, s} -> s == Blocks.portal(:x) end) end)
    assert state(pid).inventory.slots[36] == ItemStack.new("flint_and_steel", 1)
    # The Nether's regions around the scaled position start loading before anyone steps in.
    wait(fn -> warmed?(:nether_portal, bottom) end)

    # A creative player travels at once; the Nether has no portal yet, so one is made.
    client = move(client, pid, {x + 1.0, y * 1.0, z + 0.5})
    {level, {nx, ny, nz}, client} = arrive(client, pid)
    assert level == "minecraft:the_nether"
    assert state(pid).player.dimension == :the_nether
    assert abs(nx - (x + 1.0) / 8) < 17 and abs(nz - (z + 0.5) / 8) < 17
    arrival = {floor(nx), floor(ny), floor(nz)}
    assert Blocks.portal?(blocks([arrival], :the_nether)[arrival])
    # On cooldown in the new portal, the player stays.
    Process.sleep(1000)
    assert state(pid).player.dimension == :the_nether

    # Out of the portal until the cooldown ends, then back in: home through the first portal.
    client = move(client, pid, {nx + 4.0, ny + 6.0, nz + 4.0})
    wait(fn -> state(pid).player.portal_cooldown == 0 end)
    client = move(client, pid, {nx, ny, nz})
    {level, {hx, hy, hz}, client} = arrive(client, pid)
    assert level == "minecraft:overworld"
    assert {floor(hx), floor(hy), floor(hz)} in opening

    # Breaking the frame puts the portal out.
    _client = move(client, pid, {x + 6.5, y * 1.0, z + 0.5})
    set(%{{x - 1, y + 1, z} => Valimc.Registry.Blocks.default_state("air")})
    wait(fn -> Enum.all?(blocks(opening), fn {_, s} -> Blocks.air?(s) end) end)
  end

  defp ring({ix, y, iz}, eyes) do
    frame = fn facing, eye ->
      Valimc.Registry.Blocks.state("end_portal_frame", %{
        "facing" => facing,
        "eye" => to_string(eye)
      })
    end

    cells =
      for(i <- 0..2, do: {{ix + i, y, iz + 3}, "north"}) ++
        for(i <- 0..2, do: {{ix + i, y, iz - 1}, "south"}) ++
        for(i <- 0..2, do: {{ix + 3, y, iz + i}, "west"}) ++
        for(i <- 0..2, do: {{ix - 1, y, iz + i}, "east"})

    cells
    |> Enum.with_index()
    |> Map.new(fn {{cell, facing}, n} -> {cell, frame.(facing, n < eyes)} end)
  end

  # Other game events (level loading, weather) may come first.
  defp await_credits(client) do
    case Client.await(client, :play, "game_event", 2000) do
      {<<4, +0.0::float-32>>, client} -> client
      {_other, client} -> await_credits(client)
    end
  end

  test "an eye completes an end portal frame; the portal leads to the End's platform, then the credits",
       ctx do
    {x, y, z} = ctx.origin
    seed(ctx, :creative)
    {:ok, bytes} = File.read(ctx.path)
    {:ok, snapshot} = PlayerSnapshot.decode(bytes, ctx.uuid)
    snapshot = put_in(snapshot.inventory.slots[36], ItemStack.new("ender_eye", 3))
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, snapshot)
    File.write!(ctx.path, bytes)
    interior = {x, y, z}
    set(ring(interior, 11))
    {client, pid} = enter(ctx)

    # The twelfth eye, on the west side's last frame.
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(0),
      Wire.position({x - 1, y, z + 2}),
      <<1, 0.5::float-32, 1.0::float-32, 0.5::float-32, 0, 0, 9>>
    ])

    cells = for dx <- 0..2, dz <- 0..2, do: {x + dx, y, z + dz}
    portal = Valimc.Registry.Blocks.default_state("end_portal")
    wait(fn -> Enum.all?(blocks(cells), fn {_, s} -> s == portal end) end)
    assert state(pid).inventory.slots[36] == ItemStack.new("ender_eye", 3)
    wait(fn -> warmed?(:end_portal, interior) end)

    # A gateway with an exit in the platform's space is cleared like any block.
    gateway = Valimc.Registry.Blocks.default_state("end_gateway")
    {:ok, exit} = Valimc.Worldgen.FullChunk.gateway_entry({98, 50, -2}, {{1000, 80, 0}, false})

    Dimension.within(:the_end, fn ->
      set(%{{98, 50, -2} => gateway})
      :ok = Valimc.Portal.Access.put_block_entities(%{{98, 50, -2} => exit})
    end)

    client = move(client, pid, {x + 1.5, y + 0.0, z + 1.5})
    {level, {ex, ey, ez}, client} = arrive(client, pid)
    assert level == "minecraft:the_end"
    assert {ex, ey, ez} == {100.5, 49.0, 0.5}
    assert state(pid).player.yaw == 90.0
    floor = for dx <- -2..2, dz <- -2..2, do: {100 + dx, 48, dz}
    assert Enum.all?(blocks(floor, :the_end), fn {_, s} -> s == Blocks.obsidian() end)
    room = for dx <- -2..2, dz <- -2..2, dy <- 49..51, do: {100 + dx, dy, dz}
    assert Enum.all?(blocks(room, :the_end), fn {_, s} -> Blocks.air?(s) end)

    # An end portal in the End rolls the credits once, then respawns at the world spawn.
    Dimension.within(:the_end, fn -> set(%{{102, 49, 2} => portal}) end)
    wait(fn -> state(pid).player.portal_cooldown == 0 end)
    client = move(client, pid, {102.5, 49.0, 2.5})
    client = await_credits(client)
    assert state(pid).player.seen_credits
    Client.send_packet(client, :play, "client_command", <<0>>)
    {respawn, client} = Client.await(client, :play, "respawn", 2000)
    {_type, rest} = Wire.take_varint(respawn)
    {"minecraft:overworld", rest} = Wire.take_string(rest)
    assert :binary.last(rest) == 1
    {position, client} = Client.await(client, :play, "player_position")
    _client = Client.auto_reply(client, :play, "player_position", position)
    wait(fn -> state(pid).player.dimension == :overworld end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.seen_credits and Map.get(saved, :dimension, :overworld) == :overworld
  end

  defp exit_of(position) do
    Dimension.within(:the_end, fn ->
      {:ok, %{nbt: nbt}} = Valimc.Portal.Access.block_entity(position)
      {:ok, {:compound, tag}} = Valimc.NBT.read(nbt)
      {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>} = tag["exit_portal"]
      {x, y, z}
    end)
  end

  test "a gateway without an exit finds one far out, builds the exit gateway, and both lead back",
       ctx do
    seed(ctx, :creative)
    {client, pid} = enter(ctx)
    gateway = Valimc.Registry.Blocks.default_state("end_gateway")
    entry = {92, 70, 0}

    Dimension.within(:the_end, fn ->
      set(Map.new(for(dx <- 88..94, dz <- -2..2, do: {{dx, 69, dz}, Blocks.obsidian()})))
      set(%{entry => gateway})
    end)

    deadline = System.monotonic_time(:millisecond) + 5000
    pose = %{x: 89.5, y: 70.0, z: 0.5, yaw: 0.0, pitch: 0.0, dimension: :the_end}
    assert {:ok, :ok} = GenServer.call(pid, {:command_op, {:teleport, pose}, deadline}, 6000)
    {"minecraft:the_end", _, client} = arrive(client, pid)

    # Into the gateway: out along its direction, about 1,024 blocks from the origin.
    client = move(client, pid, {92.5, 70.0, 0.5})
    {position, client} = Client.await(client, :play, "player_position", 4000)
    {_, <<x::float-64, _y::float-64, z::float-64, _::binary>>} = Wire.take_varint(position)
    client = Client.auto_reply(client, :play, "player_position", position)
    assert state(pid).player.dimension == :the_end
    assert :math.sqrt(x * x + z * z) > 700
    exit = exit_of(entry)
    {ex, ey, ez} = exit
    assert blocks([exit], :the_end)[exit] == gateway

    assert blocks([{ex, ey - 2, ez}], :the_end)[{ex, ey - 2, ez}] ==
             Valimc.Registry.Blocks.default_state("bedrock")

    assert exit_of(exit) == entry
    assert abs(x - (ex + 0.5)) <= 6 and abs(z - (ez + 0.5)) <= 6

    # And back through the exit gateway, near the first one. The gateway's
    # teleport follows the command's before the client confirms that one; the
    # stale confirmation is ignored, as vanilla's.
    wait(fn -> state(pid).player.portal_cooldown == 0 end)
    deadline = System.monotonic_time(:millisecond) + 2000
    pose = %{x: ex + 0.5, y: ey * 1.0, z: ez + 0.5, yaw: 0.0, pitch: 0.0}
    :ok = GenServer.call(pid, {:teleport, pose, deadline})
    {command, client} = Client.await(client, :play, "player_position")
    {gateway_teleport, client} = Client.await(client, :play, "player_position", 4000)
    client = Client.auto_reply(client, :play, "player_position", command)
    _client = Client.auto_reply(client, :play, "player_position", gateway_teleport)

    wait(fn ->
      p = state(pid).player
      abs(p.x - 92.5) <= 6 and abs(p.z - 0.5) <= 6
    end)

    wait(fn -> not state(pid).teleport_pending end)

    # Both exits survive their regions reloading from disk.
    for {x, _, z} <- [entry, exit],
        key = Dimension.scope(:the_end, World.region_key(World.chunk_key(x, z))),
        {owner, _} <- Registry.lookup(Valimc.RegionRegistry, key),
        do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, owner)

    assert exit_of(entry) == exit and exit_of(exit) == entry
  end
end
