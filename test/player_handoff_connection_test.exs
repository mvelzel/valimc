defmodule Valimc.PlayerHandoffConnectionTest do
  # A hosted player's move between groups is two-phase (VMC-077s, VMC-077y):
  # the group lets it go only once the target holds it, and a group left with
  # nothing retires.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Player.ChunkView
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.{TestConn, TestPlayer, TestScope, TestWait, TestWorld}
  alias Valimc.World.Region

  setup do
    ctx = TestPlayer.scope("Hand", {46_000, 760})
    # The test, not the regionizer, decides which group holds which section.
    TestScope.isolate(TestScope.neighborhood(ctx.key, 3), regionizer: false)
    TestPlayer.save(ctx, ctx.pose, Valimc.Menus.Inventory.new())
    {rx, rz} = ctx.key
    Map.merge(ctx, %{east: {rx + 1, rz}, east_pose: %{ctx.pose | x: ctx.pose.x + 128}})
  end

  defp group(pid), do: :sys.get_state(pid).owner
  defp registered?(uuid), do: Registry.lookup(Valimc.PlayerRegistry, uuid) != []

  test "a target that stops before adopting leaves the player with its group; a rejoin works",
       ctx do
    {client, pid} = TestPlayer.login(ctx)
    source = group(pid)
    {:ok, {target, _}} = TestWorld.owner(ctx.east)
    assert target != source

    # The target holds the player unread in its mailbox when it dies.
    :sys.suspend(target)
    :ok = TestConn.teleport(pid, ctx.east_pose)

    TestWait.until(fn ->
      {:messages, messages} = Process.info(target, :messages)
      Enum.any?(messages, &match?({:adopt, _, _, [], [_]}, &1))
    end)

    # A call made meanwhile goes on to the target too; the group runs it
    # once the player is its own again.
    turn =
      Task.async(fn ->
        TestConn.call(pid, fn s -> {:reply, :turned, %{s | player: %{s.player | yaw: 90.0}}} end)
      end)

    TestWait.until(fn ->
      {:messages, messages} = Process.info(target, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:player_call, _, {:debug_call, _}}}, &1))
    end)

    TestScope.kill(target)
    assert Task.await(turn, 30_000) == :turned

    # The group resumes the player: still its own, then handed to the
    # section's new group once that loads.
    TestWait.until(fn ->
      owner = group(pid)

      owner != target and Process.alive?(owner) and
        Map.has_key?(:sys.get_state(owner).players, ctx.uuid)
    end)

    assert %{x: x, yaw: 90.0} = TestConn.state(pid).player
    assert x == ctx.east_pose.x
    TestWait.until(fn -> TestWorld.existing_owner(ctx.east) |> elem(0) == :ok end)
    TestWait.until(fn -> :sys.get_state(group(pid)).sections |> Map.has_key?(ctx.east) end)

    Client.close(client)
    TestWait.until(fn -> not registered?(ctx.uuid) end)

    {_client, pid} = TestPlayer.login(ctx)
    assert TestConn.state(pid).player.x == ctx.east_pose.x
  end

  test "a player rides its section's transfer; the group left with nothing retires", ctx do
    {client, pid} = TestPlayer.login(ctx)
    source = group(pid)
    {:ok, {target, _}} = TestWorld.owner(ctx.east)
    ref = Process.monitor(source)
    {:ok, [_]} = Region.hand_over(source, target)

    # The registration follows the player: only the target holds it.
    assert_receive {:DOWN, ^ref, :process, ^source, :normal}, 5_000
    TestWait.until(fn -> group(pid) == target end)
    assert [{^target, :hosted}] = Registry.lookup(Valimc.PlayerRegistry, ctx.uuid)

    Client.close(client)
    TestWait.until(fn -> not registered?(ctx.uuid) end)
  end

  # Flies `steps` client ticks east at `speed` blocks each, reading what
  # arrives meanwhile: `{client, pose, owners seen, chunk events}`.
  defp fly(client, pid, pose, steps, speed, acc \\ {[], []})

  defp fly(client, _pid, pose, 0, _speed, {owners, events}),
    do: {client, pose, Enum.reverse(owners), Enum.reverse(events)}

  defp fly(client, pid, pose, steps, speed, {owners, events}) do
    pose = %{pose | x: pose.x + speed}

    client =
      client
      |> Client.send_packet(
        :play,
        "move_player_pos",
        <<pose.x::float-64, pose.y::float-64, pose.z::float-64, 0>>
      )
      |> Client.send_packet(:play, "client_tick_end", <<>>)

    {client, events} = drain(client, System.monotonic_time(:millisecond) + 10, events)
    owner = group(pid)
    owners = if match?([^owner | _], owners), do: owners, else: [owner | owners]
    fly(client, pid, pose, steps - 1, speed, {owners, events})
  end

  defp drain(client, until, events) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        client = %{client | buffer: rest}
        name = Data.name(:play, :clientbound, id)
        client = Client.auto_reply(client, :play, name, body)

        event =
          case {name, body} do
            {"level_chunk_with_light", <<x::signed-32, z::signed-32, _::binary>>} ->
              {:chunk, {x, z}}

            {"forget_level_chunk", <<z::signed-32, x::signed-32>>} ->
              {:forget, {x, z}}

            {"set_chunk_cache_center", center} ->
              {:center, center(center)}

            {"player_position", _} ->
              :corrected

            {"respawn", _} ->
              :respawn

            _ ->
              nil
          end

        drain(client, until, if(event, do: [event | events], else: events))

      :more ->
        wait = until - System.monotonic_time(:millisecond)

        case wait > 0 && :gen_tcp.recv(client.socket, 0, wait) do
          {:ok, data} -> drain(%{client | buffer: client.buffer <> data}, until, events)
          _ -> {client, events}
        end
    end
  end

  defp center(body) do
    {x, rest} = Wire.take_varint(body)
    {z, _} = Wire.take_varint(rest)
    {signed(x), signed(z)}
  end

  defp signed(n), do: if(n >= 0x80000000, do: n - 0x100000000, else: n)

  test "flying across groups hands the player on without resetting the client's chunks", ctx do
    {client, pid} = TestPlayer.login(ctx)

    TestConn.replace(pid, fn s ->
      {_, s} = Valimc.Player.GameModes.set(s, :spectator)
      s
    end)

    start = Map.take(TestConn.state(pid).player, [:x, :y, :z])
    {client, pose, owners, events} = fly(client, pid, start, 400, 0.9)
    {_, events_after} = drain(client, System.monotonic_time(:millisecond) + 500, [])
    events = events ++ Enum.reverse(events_after)

    # Three groups held the player in turn; the client was never respawned
    # or corrected.
    assert length(owners) >= 3
    refute :respawn in events or :corrected in events
    assert TestConn.state(pid).player.x == pose.x

    # Every chunk the client forgot had left the view it was then told;
    # it ends with every chunk of its view.
    {_, distance} = TestConn.state(pid).view
    first = Valimc.Data.Grid.chunk_key(start.x, start.z)

    {center, loaded} =
      Enum.reduce(events, {first, MapSet.new(ChunkView.chunks({first, distance}))}, fn
        {:center, center}, {_, loaded} ->
          {center, loaded}

        {:forget, chunk}, {center, loaded} ->
          refute ChunkView.contains?({center, distance}, chunk)
          {center, MapSet.delete(loaded, chunk)}

        {:chunk, chunk}, {center, loaded} ->
          {center, MapSet.put(loaded, chunk)}

        _, acc ->
          acc
      end)

    assert center == Valimc.Data.Grid.chunk_key(pose.x, pose.z)
    assert MapSet.subset?(MapSet.new(ChunkView.chunks({center, distance})), loaded)
  end
end
