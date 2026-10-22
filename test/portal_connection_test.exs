defmodule Valimc.PortalConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  @moduletag :slow
  @moduletag timeout: 240_000
  alias Valimc.World.Dimension
  alias Valimc.Menus.Inventory
  alias Valimc.Player.PlayerList
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Blocks.PortalBlocks
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Portal#{nonce}"
    uuid = Valimc.Data.UUID.offline(name)
    base = Path.join(System.tmp_dir!(), "valimc-portal-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    # An overworld region of its own; its Nether counterpart is an eighth of it.
    {rx, rz} = key = {64 + rem(nonce, 200) * 2, 40}
    origin = {rx * 128 + 40, 64, rz * 128 + 40}

    on_exit(fn ->
      for p <- PlayerList.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      # The overworld regions and stores around the portal and the world spawn
      # (the credits' respawn lands there, and its owners may still be loading).
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_dimensions()
      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      key: key,
      base: base,
      origin: origin,
      path: Valimc.Player.Storage.path(base, uuid)
    }
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  # Wait until the player has ticked `count` more times.
  defp ticks(pid, count) do
    from = state(pid).simulation_clock.tick
    wait(fn -> state(pid).simulation_clock.tick >= from + count end)
  end

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
      living: %Valimc.Living{freezing: %Freezing{}, health: %Health{}, air_supply: 300},
      x: x + 3.5,
      y: y * 1.0,
      z: z + 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(mode),
      abilities: Valimc.Player.Abilities.for_mode(mode),
      motion: %Valimc.Player.Motion{},
      last_death: nil
    }

    inventory = %Inventory{slots: %{36 => ItemStack.new("flint_and_steel", 1)}}
    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp enter(ctx) do
    {_, client} = Client.login(ctx.name)
    pid = wait(fn -> Enum.find(PlayerList.all(), &(&1.name == ctx.name)) end).pid
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> not state(pid).teleport_pending end)
    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  # An obsidian frame with a 2 × 3 opening from `{x, y, z}` along X.
  defp frame({x, y, z}) do
    for dx <- -1..2, dy <- -1..3, dx in [-1, 2] or dy in [-1, 3], into: %{} do
      {{x + dx, y + dy, z}, PortalBlocks.obsidian()}
    end
  end

  # Owners still generating answer late; the portal commits retry them.
  defp set(edits), do: :ok = Valimc.World.Portal.Access.commit(Map.to_list(edits))

  # The destination's regions a lit or opened portal admits ahead of the player.
  defp warmed?(kind, position) do
    {dimension, area} = Valimc.World.Portal.Warm.area(kind, position)

    Dimension.within(dimension, fn ->
      Enum.all?(Valimc.World.Portal.Warm.regions(area), &Valimc.TestWorld.lookup/1)
    end)
  end

  defp blocks(positions, dimension \\ :overworld) do
    Dimension.within(dimension, fn ->
      read = Valimc.World.Portal.Access.reader()
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
    wait(fn -> Enum.all?(blocks(opening), fn {_, s} -> s == PortalBlocks.portal(:x) end) end)
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
    assert PortalBlocks.portal?(blocks([arrival], :the_nether)[arrival])
    # On cooldown in the new portal, the player stays.
    ticks(pid, 20)
    assert state(pid).player.dimension == :the_nether

    # Out of the portal until the cooldown ends, then back in: home through the first portal.
    client = move(client, pid, {nx + 4.0, ny + 6.0, nz + 4.0})
    wait(fn -> state(pid).player.portal_cooldown == 0 end)
    client = move(client, pid, {nx, ny, nz})
    {level, {hx, hy, hz}, client} = arrive(client, pid)
    assert level == "minecraft:overworld"
    assert {floor(hx), floor(hy), floor(hz)} in opening

    # A teleport across the portal's plane is no walk through it (VMC-026c).
    client = move(client, pid, {x + 1.0, y * 1.0, z + 2.5})
    wait(fn -> state(pid).player.portal_cooldown == 0 end)
    client = move(client, pid, {x + 1.0, y * 1.0, z - 1.5})
    ticks(pid, 10)
    assert state(pid).player.dimension == :overworld and state(pid).portal.process == nil

    # Breaking the frame puts the portal out.
    _client = move(client, pid, {x + 6.5, y * 1.0, z + 0.5})
    set(%{{x - 1, y + 1, z} => Valimc.Data.Blocks.default_state("air")})
    wait(fn -> Enum.all?(blocks(opening), fn {_, s} -> PortalBlocks.air?(s) end) end)
  end

  defp ring({ix, y, iz}, eyes) do
    frame = fn facing, eye ->
      Valimc.Data.Blocks.state("end_portal_frame", %{
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
    {:ok, snapshot} = PlayerState.decode(bytes, ctx.uuid)
    snapshot = put_in(snapshot.inventory.slots[36], ItemStack.new("ender_eye", 3))
    {:ok, bytes} = PlayerState.encode(ctx.uuid, snapshot)
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
    portal = Valimc.Data.Blocks.default_state("end_portal")
    wait(fn -> Enum.all?(blocks(cells), fn {_, s} -> s == portal end) end)
    assert state(pid).inventory.slots[36] == ItemStack.new("ender_eye", 3)
    wait(fn -> warmed?(:end_portal, interior) end)

    # A gateway with an exit in the platform's space is cleared like any block.
    gateway = Valimc.Data.Blocks.default_state("end_gateway")
    {:ok, exit} = Valimc.Worldgen.FullChunk.gateway_entry({98, 50, -2}, {{1000, 80, 0}, false})

    Dimension.within(:the_end, fn ->
      set(%{{98, 50, -2} => gateway})
      :ok = Valimc.World.Portal.Access.put_block_entities(%{{98, 50, -2} => exit})
    end)

    client = move(client, pid, {x + 1.5, y + 0.0, z + 1.5})
    {level, {ex, ey, ez}, client} = arrive(client, pid)
    assert level == "minecraft:the_end"
    assert {ex, ey, ez} == {100.5, 49.0, 0.5}
    assert state(pid).player.yaw == 90.0
    floor = for dx <- -2..2, dz <- -2..2, do: {100 + dx, 48, dz}
    assert Enum.all?(blocks(floor, :the_end), fn {_, s} -> s == PortalBlocks.obsidian() end)
    room = for dx <- -2..2, dz <- -2..2, dy <- 49..51, do: {100 + dx, dy, dz}
    assert Enum.all?(blocks(room, :the_end), fn {_, s} -> PortalBlocks.air?(s) end)

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
    Valimc.TestPlayer.checkpointed(pid)
    {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.seen_credits and Map.get(saved, :dimension, :overworld) == :overworld
  end
end
