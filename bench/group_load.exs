# A player's group under a wide view (VMC-077s): a fresh generated world, one
# spectator flying fast (through terrain) at view distance 32 with simulation distance 10,
# the way a live test found the group process saturated (scheduled ticks of
# unsimulated chunks churned every tick, and every tick's storage diff rebuilt
# every record).
#
#   MIX_ENV=bench mix run --no-start bench/group_load.exs <scratch-dir> [results.json] [seconds]
#
# Every 50 ms it samples the process hosting the player: its mailbox length and
# reductions. Reported: those per second, the server's tick times (`TickRate`),
# the movement corrections, the player's handoffs between groups, how far the
# chunk center the server last sent trails the client (in chunks: past the
# view distance the client shows nothing) and how far the player got.
Code.require_file("test/support/client.ex")

defmodule Bench.GroupLoad do
  alias Valimc.Player.PlayerList
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.TestClient, as: Client

  @speed 1.0

  def run(base, seconds) do
    name = "Flyer"
    {_uuid, client} = Client.configure_session(Client.begin_login(name), name)

    settings = [Wire.string("en_us"), <<32::signed-8, 0, 1, 0x7F, 1, 0, 1, 0>>]
    client = Client.send_packet(client, :configuration, "client_information", settings)
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_login, client} = Client.await(client, :play, "login")
    {position, client} = Client.await(client, :play, "player_position")

    {_, <<x::float-64, y::float-64, z::float-64, _::binary>>} = Wire.take_varint(position)
    client = Client.auto_reply(client, :play, "player_position", position)
    client = Client.load_world(client, 49)
    client = Client.send_packet(client, :play, "player_loaded", <<>>)

    pid =
      Valimc.TestWait.until(fn ->
        Enum.find_value(PlayerList.all(), &(&1.name == name && &1.pid))
      end)

    Valimc.TestConn.replace(pid, fn s ->
      {_, s} = Valimc.Player.GameModes.set(s, :spectator)
      s
    end)

    client = Client.send_packet(client, :play, "player_abilities", <<2>>)
    _ = base
    Process.sleep(500)
    start = %{x: x, y: y, z: z}
    metrics = Valimc.Data.Metrics.snapshot()
    {_, ticks_before} = Valimc.World.TickRate.samples()
    stop = System.monotonic_time(:millisecond) + seconds * 1000
    sampler = Task.async(fn -> sample(pid, stop, []) end)
    {client, last, lags} = fly(Map.put(client, :center, nil), start, stop, [])
    samples = Task.await(sampler, :infinity)
    {tick_samples, ticks_after} = Valimc.World.TickRate.samples()
    after_metrics = Valimc.Data.Metrics.snapshot()
    Client.close(client)

    queue = Enum.map(samples, & &1.queue)
    reductions = samples |> Enum.map(& &1.reductions) |> rates()
    ticks = ticks_after - ticks_before

    recent =
      tick_samples |> Enum.reject(&(&1 == 0)) |> Enum.take(-min(ticks, length(tick_samples)))

    corrections =
      for {key, value} <- after_metrics,
          String.contains?(to_string(key), "correction") or
            String.contains?(to_string(key), "handoffs"),
          value != Map.get(metrics, key, 0),
          into: %{},
          do: {key, value - Map.get(metrics, key, 0)}

    %{
      seconds: seconds,
      distance: Float.round(last.x - start.x, 1),
      ticks: ticks,
      tick_ms: stats(Enum.map(recent, &(&1 / 1_000_000))),
      group_queue: stats(queue),
      group_reductions_per_second: stats(reductions),
      center_lag_chunks: stats(lags),
      corrections: corrections
    }
  end

  # East along x at `@speed` blocks a client tick, climbing to y 140 first.
  defp fly(client, pose, stop, lags) do
    if System.monotonic_time(:millisecond) >= stop do
      {client, pose, lags}
    else
      pose = %{pose | x: pose.x + @speed, y: min(pose.y + @speed, 140.0)}

      client =
        client
        |> Client.send_packet(
          :play,
          "move_player_pos",
          <<pose.x::float-64, pose.y::float-64, pose.z::float-64, 0>>
        )
        |> Client.send_packet(:play, "client_tick_end", <<>>)
        |> Map.put(:corrected, nil)
        |> drain(System.monotonic_time(:millisecond) + 50)

      lags = if client.center, do: [lag(client.center, pose) | lags], else: lags
      fly(client, corrected(client, pose), stop, lags)
    end
  end

  defp signed(n), do: if(n >= 0x80000000, do: n - 0x100000000, else: n)

  defp lag({cx, cz}, pose) do
    {x, z} = Valimc.Data.Grid.chunk_key(pose.x, pose.z)
    max(abs(x - cx), abs(z - cz))
  end

  # A correction moves the player back: the client continues from there.
  defp corrected(%{corrected: nil}, pose), do: pose
  defp corrected(%{corrected: at}, pose), do: Map.merge(pose, at)

  defp drain(client, until) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        client = %{client | buffer: rest}
        name = Data.name(:play, :clientbound, id)
        client = Client.auto_reply(client, :play, name, body)

        client =
          case name do
            "player_position" ->
              {_, <<x::float-64, y::float-64, z::float-64, _::binary>>} = Wire.take_varint(body)
              Map.put(client, :corrected, %{x: x, y: y, z: z})

            "set_chunk_cache_center" ->
              {x, rest} = Wire.take_varint(body)
              {z, _} = Wire.take_varint(rest)
              Map.put(client, :center, {signed(x), signed(z)})

            _ ->
              client
          end

        drain(client, until)

      :more ->
        wait = until - System.monotonic_time(:millisecond)

        if wait <= 0 do
          client
        else
          case :gen_tcp.recv(client.socket, 0, wait) do
            {:ok, data} -> drain(%{client | buffer: client.buffer <> data}, until)
            {:error, :timeout} -> client
          end
        end
    end
  end

  defp sample(pid, stop, acc) do
    if System.monotonic_time(:millisecond) >= stop do
      Enum.reverse(acc)
    else
      owner = :sys.get_state(pid).owner

      if System.get_env("PROFILE") do
        case Process.info(owner, [:message_queue_len, :current_stacktrace, :messages]) do
          [message_queue_len: q, current_stacktrace: stack, messages: messages] when q > 200 ->
            kinds =
              messages
              |> Enum.take(400)
              |> Enum.map(fn
                {:"$gen_call", _, request} when is_tuple(request) -> {:call, elem(request, 0)}
                {:"$gen_call", _, request} -> {:call, request}
                {:"$gen_cast", request} when is_tuple(request) -> {:cast, elem(request, 0)}
                message when is_tuple(message) -> elem(message, 0)
                message -> message
              end)
              |> Enum.frequencies()
              |> Enum.sort_by(&(-elem(&1, 1)))
              |> Enum.take(6)

            IO.puts("PROFILE q=#{q} at #{inspect(Enum.take(stack, 3))} kinds=#{inspect(kinds)}")

          _ ->
            :ok
        end
      end

      acc =
        case Process.info(owner, [:message_queue_len, :reductions]) do
          [message_queue_len: queue, reductions: reductions] ->
            [
              %{
                queue: queue,
                reductions: {owner, reductions, System.monotonic_time(:millisecond)}
              }
              | acc
            ]

          nil ->
            acc
        end

      Process.sleep(50)
      sample(pid, stop, acc)
    end
  end

  # Reductions per second between samples of the same process.
  defp rates(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{a, ra, ta}, {b, rb, tb}] ->
      if a == b and tb > ta, do: [div((rb - ra) * 1000, tb - ta)], else: []
    end)
  end

  def stats([]), do: %{samples: 0}

  def stats(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      samples: n,
      p50: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, min(n - 1, trunc(n * 0.95))),
      max: List.last(sorted),
      mean: Enum.sum(sorted) / n
    }
  end
end

[base | rest] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :generator, :vanilla)
Application.put_env(:valimc, :view_distance, 32)
Application.put_env(:valimc, :simulation_distance, 10)
{:ok, _} = Application.ensure_all_started(:valimc)

seconds =
  case rest do
    [_, seconds | _] -> String.to_integer(seconds)
    _ -> 40
  end

result = Bench.GroupLoad.run(base, seconds)
commit = System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()
IO.inspect(result, label: "group load")

case rest do
  [out | _] -> File.write!(out, :json.encode(Map.put(result, :commit, commit)))
  [] -> :ok
end
