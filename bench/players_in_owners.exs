# PlayerList in owners (VMC-077i): item pickup and chest-click latency over real
# sockets, group tick time with 1, 10 and 50 players moving in one group, and
# memory per connection.
#
#   MIX_ENV=bench mix run --no-start bench/players_in_owners.exs <scratch-dir> [results.json]
#
# Latency is from the server-side action (an item created at the player, a
# click sent) to the packet that shows its effect (`take_item_entity`,
# `set_cursor_item`). Tick time is every group tick sampled while the players
# move (`TickRate` samples); reductions are the group's and the connections'
# per tick, a CPU proxy that stays comparable when work moves between them.
# Memory is the connection's heap and, with players in owners, the session's
# share of its group's (a player store before).
Code.require_file("test/support/client.ex")

defmodule Bench.PlayersInOwners do
  alias Valimc.Net.Connection
  alias Valimc.Player.{GameMode, PlayerList}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World
  alias Valimc.World.{Containers, Region}

  @chest "priv/protocol/chest_states.json"
         |> File.read!()
         |> JSON.decode!()
         |> Map.fetch!("single_states")
         |> hd()

  def pose(i), do: %{x: 8.5 + rem(i, 8), y: 64.0, z: 8.5 + div(i, 8), yaw: 0.0, pitch: 0.0}

  # A survival player saved at `pose` before its first login.
  def seed(base, name, pose, inventory \\ %Inventory{}) do
    uuid = Valimc.Data.UUID.offline(name)

    player =
      Map.merge(pose, %{
        game_mode: GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival)
      })

    {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(player, inventory))
    path = Valimc.Player.Storage.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    uuid
  end

  def login(name) do
    {_, client} = Client.login(name)
    client = Client.load_world(client)
    client = Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(PlayerList.all(), &(&1.name == name)).pid
    Process.sleep(300)
    {client, pid}
  end

  def logout(client, name) do
    Client.close(client)
    Valimc.TestWait.until(fn -> Enum.all?(PlayerList.all(), &(&1.name != name)) end, 30_000)
  end

  def owner(%{x: x, z: z}),
    do: World.item_owner(Valimc.Data.Grid.section(:overworld, Valimc.Data.Grid.chunk_key(x, z)))

  def pickup(base) do
    pose = pose(0)
    seed(base, "PickBench", pose)
    {client, _pid} = login("PickBench")
    {:ok, owner} = owner(pose)

    {client, times} =
      Enum.reduce(1..30, {client, []}, fn _, {client, times} ->
        started = System.monotonic_time(:microsecond)

        {:ok, {_, _, id, _}} =
          Region.create_item(owner, ItemStack.new("stone"), {pose.x, pose.y, pose.z})

        client = await_entity(client, "take_item_entity", id)
        {client, [System.monotonic_time(:microsecond) - started | times]}
      end)

    logout(client, "PickBench")
    stats(times)
  end

  def chest(base) do
    pose = pose(0)
    position = {floor(pose.x), 64, floor(pose.z) + 2}
    key = Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(pose.x, pose.z))
    seed(base, "ChestBench", pose)
    {:ok, containers, entry} = Containers.create(%Containers{}, key, position, 3)
    slots = put_elem(entry.slots, 0, ItemStack.new("diamond", 3))
    {:ok, containers, _} = Containers.replace(containers, position, entry.revision, slots)
    {:ok, bytes} = Containers.encode(key, containers)
    Valimc.TestDisk.write(base, key, :containers, bytes)
    Valimc.TestDisk.write(base, key, :blocks, %{position => @chest})
    {client, _pid} = login("ChestBench")

    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(0),
      Wire.position(position),
      <<0, 0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
    ])

    {body, client} = Client.await(client, :play, "open_screen")
    {window, _} = Wire.take_varint(body)
    {_, client} = Client.await(client, :play, "set_cursor_item")

    {client, times} =
      Enum.reduce(1..30, {client, []}, fn _, {client, times} ->
        started = System.monotonic_time(:microsecond)

        Client.send_packet(client, :play, "container_click", [
          Wire.varint(window),
          <<0, 0::signed-16, 0::signed-8>>,
          Wire.varint(ItemTypes.input_id("pickup")),
          <<1, 0::signed-16, 0, 0>>
        ])

        {_, client} = Client.await(client, :play, "set_cursor_item")
        {client, [System.monotonic_time(:microsecond) - started | times]}
      end)

    logout(client, "ChestBench")
    stats(times)
  end

  # `count` players move in one group for five seconds.
  def ticks(base, count) do
    names = for i <- 1..count, do: "Tick#{count}N#{i}"

    clients =
      for {name, i} <- Enum.with_index(names) do
        seed(base, name, pose(i))
        {client, pid} = login(name)
        {name, client, pid, i}
      end

    {:ok, {group, _}} = owner(pose(0))
    memory = for {_, _, pid, _} <- clients, do: elem(Process.info(pid, :memory), 1)

    # A session its group hosts (VMC-077i3) is part of the group's heap.
    session_memory =
      for {_, entry} <- Map.get(:sys.get_state(group), :players, %{}),
          do: :erts_debug.flat_size(entry.session) * :erlang.system_info(:wordsize)

    group_reductions = reductions([group])
    connection_reductions = reductions(for {_, _, pid, _} <- clients, do: pid)
    {_, count_before} = Valimc.World.TickRate.samples()
    stop = System.monotonic_time(:millisecond) + 5000

    movers =
      for {_name, client, _pid, i} <- clients,
          do: Task.async(fn -> move(client, pose(i), stop, 0) end)

    finals = Enum.map(movers, &Task.await(&1, 30_000))
    {samples, count_after} = Valimc.World.TickRate.samples()
    ticks = count_after - count_before
    recent = samples |> Enum.reject(&(&1 == 0)) |> Enum.take(-min(ticks, length(samples)))

    result = %{
      players: count,
      ticks: ticks,
      tick_us: stats(Enum.map(recent, &div(&1, 1000))),
      group_reductions_per_tick: div(reductions([group]) - group_reductions, max(ticks, 1)),
      connection_reductions_per_tick:
        div(
          reductions(for {_, _, pid, _} <- clients, do: pid) - connection_reductions,
          max(ticks, 1)
        ),
      connection_bytes: div(Enum.sum(memory), count),
      session_bytes: div(Enum.sum(session_memory), count)
    }

    for {{name, _, _, _}, client} <- Enum.zip(clients, finals), do: logout(client, name)
    result
  end

  defp reductions(pids),
    do:
      Enum.sum(
        for pid <- pids,
            {:reductions, n} <- [Process.info(pid, :reductions)],
            do: n
      )

  # Small steps every 50 ms, draining what the server sends.
  defp move(client, pose, stop, step) do
    if System.monotonic_time(:millisecond) >= stop do
      client
    else
      x = pose.x + :math.sin(step / 8) * 0.2

      client =
        client
        |> Client.send_packet(
          :play,
          "move_player_pos",
          <<x::float-64, 64.0::float-64, pose.z::float-64, 1>>
        )
        |> Client.send_packet(:play, "client_tick_end", <<>>)
        |> drain(System.monotonic_time(:millisecond) + 50)

      move(client, pose, stop, step + 1)
    end
  end

  defp drain(client, until) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        client = %{client | buffer: rest}
        client = Client.auto_reply(client, :play, Data.name(:play, :clientbound, id), body)
        drain(client, until)

      :more ->
        wait = until - System.monotonic_time(:millisecond)

        if wait <= 0 do
          client
        else
          case :gen_tcp.recv(client.socket, 0, wait) do
            {:ok, bytes} -> drain(%{client | buffer: client.buffer <> bytes}, until)
            {:error, :timeout} -> client
          end
        end
    end
  end

  defp await_entity(client, name, id) do
    {body, client} = Client.await(client, :play, name, 5000)

    case Wire.take_varint(body) do
      {^id, _} -> client
      _ -> await_entity(client, name, id)
    end
  end

  def stats([]), do: %{samples: 0}

  def stats(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      samples: n,
      p50: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, min(n - 1, trunc(n * 0.95))),
      mean: div(Enum.sum(sorted), n)
    }
  end
end

[base | rest] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :cooking_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)

# The chest's fixture seeds the spawn region before anything loads it.
chest = Bench.PlayersInOwners.chest(base)

results = %{
  chest_click_us: chest,
  pickup_us: Bench.PlayersInOwners.pickup(base),
  ticks: for(count <- [1, 10, 50], do: Bench.PlayersInOwners.ticks(base, count))
}

json =
  :json.encode(%{
    workload:
      "players in owners: pickup and chest-click latency (30 each), group tick with 1/10/50 moving players, memory per connection",
    commit: String.trim(elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0)),
    schedulers: System.schedulers_online(),
    results: results
  })

IO.puts(json)
if rest != [], do: File.write!(hd(rest), json)
