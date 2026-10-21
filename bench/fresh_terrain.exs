# How fast a player's view fills over terrain no region has generated yet
# (VMC-071). One real loopback TCP client at view distance 10 acknowledges every
# batch at 64 chunks per tick (vanilla's maximum rate), then the server teleports
# it into fresh terrain several times. Per hop: time to the first new chunk and to
# the whole 473-chunk view, and the server's generation and region-load counters.
#
#   VALIMC_GENERATOR=vanilla VALIMC_SEED=20261020 VALIMC_WORLD=<fresh dir> \
#     VALIMC_PORT=0 VALIMC_VIEW_DISTANCE=10 MIX_ENV=prod \
#     mix run bench/fresh_terrain.exs bench/results/fresh-terrain.json [hops] [hop_blocks]
alias Valimc.Protocol.{Data, Wire}
alias Valimc.Session.ChunkView

[output | rest] = System.argv()
hops = String.to_integer(Enum.at(rest, 0, "6"))
hop_blocks = String.to_integer(Enum.at(rest, 1, "512"))
distance = 10
%{generator: :vanilla, seed: seed} = Valimc.World.Spec.current()
now = fn -> System.monotonic_time(:microsecond) end

defmodule Bench.Client do
  alias Valimc.Protocol.{Data, Wire}

  def send(client, phase, name, payload) do
    :ok =
      :gen_tcp.send(
        client.socket,
        Wire.frame(Data.id(phase, :serverbound, name), payload, client.threshold)
      )

    client
  end

  def read(client) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        {id, body, %{client | buffer: rest}}

      :more ->
        case :gen_tcp.recv(client.socket, 0, 30_000) do
          {:ok, bytes} ->
            read(%{client | buffer: client.buffer <> bytes})

          error ->
            receive do
              {:DOWN, _, :process, _, reason} -> raise "connection ended: #{inspect(reason)}"
            after
              1000 -> raise "socket #{inspect(error)}"
            end
        end
    end
  end

  def await(client, phase, name) do
    {id, body, client} = read(client)

    if Data.name(phase, :clientbound, id) == name,
      do: {body, client},
      else: await(client, phase, name)
  end
end

alias Bench.Client

{:ok, socket} =
  :gen_tcp.connect({127, 0, 0, 1}, Valimc.Listener.port(), [:binary, active: false], 5000)

name = "FreshBench"
client = %{socket: socket, buffer: <<>>, threshold: nil}

client =
  client
  |> Client.send(:handshake, "intention", [
    Wire.varint(777),
    Wire.string("localhost"),
    <<25565::16, 2>>
  ])
  |> Client.send(:login, "hello", [Wire.string(name), <<0::128>>])

{body, client} = Client.await(client, :login, "login_compression")
{threshold, <<>>} = Wire.take_varint(body)
client = %{client | threshold: threshold}
{_, client} = Client.await(client, :login, "login_finished")
client = Client.send(client, :login, "login_acknowledged", <<>>)
{packs, client} = Client.await(client, :configuration, "select_known_packs")

client =
  client
  |> Client.send(:configuration, "client_information", [
    Wire.string("en_us"),
    <<distance::signed-8, 0, 1, 0x7F, 1, 0, 1, 0>>
  ])
  |> Client.send(:configuration, "select_known_packs", packs)

{_, client} = Client.await(client, :configuration, "finish_configuration")
client = Client.send(client, :configuration, "finish_configuration", <<>>)
{_, client} = Client.await(client, :play, "login")

pid =
  Enum.find_value(1..1000, fn _ ->
    Enum.find_value(Valimc.Players.all(), &if(&1.name == name, do: &1.pid)) ||
      (Process.sleep(5) && nil)
  end) || raise "player did not register"

Process.monitor(pid)

# The connection's largest mailbox since the last reading; past `max_mailbox`
# (256) a connection is stopped as overloaded.
sampler =
  spawn_link(fn ->
    loop = fn loop, peak ->
      receive do
        {:take, from} ->
          send(from, {:peak, peak})
          loop.(loop, 0)
      after
        2 ->
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, size} -> loop.(loop, max(peak, size))
            nil -> loop.(loop, peak)
          end
      end
    end

    loop.(loop, 0)
  end)

peak = fn ->
  send(sampler, {:take, self()})

  receive do
    {:peak, peak} -> peak
  end
end

# Reads until the view around `center` holds every chunk; returns the client and
# the microseconds to its first and last new chunk after `started`.
fill = fn fill, client, view, have, started, first ->
  if MapSet.subset?(view, have) do
    {client, first, now.() - started, have}
  else
    {id, body, client} = Client.read(client)

    case {Data.name(:play, :clientbound, id), body} do
      {"level_chunk_with_light", <<x::signed-32, z::signed-32, _::binary>>} ->
        first = first || now.() - started
        fill.(fill, client, view, MapSet.put(have, {x, z}), started, first)

      {"forget_level_chunk", <<z::signed-32, x::signed-32>>} ->
        fill.(fill, client, view, MapSet.delete(have, {x, z}), started, first)

      {"chunk_batch_finished", _} ->
        client = Client.send(client, :play, "chunk_batch_received", <<64.0::float-32>>)
        fill.(fill, client, view, have, started, first)

      {"disconnect", body} ->
        raise "disconnected after #{div(now.() - started, 1000)} ms: #{inspect(body, limit: 200)}"

      {"keep_alive", body} ->
        fill.(fill, Client.send(client, :play, "keep_alive", body), view, have, started, first)

      {"player_position", body} ->
        {teleport,
         <<x::float-64, y::float-64, z::float-64, _::binary-size(24), yaw::float-32,
           pitch::float-32, _::32>>} = Wire.take_varint(body)

        client =
          Client.send(client, :play, "accept_teleportation", [
            Wire.varint(teleport),
            <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32>>
          ])

        fill.(fill, client, view, have, started, first)

      _ ->
        fill.(fill, client, view, have, started, first)
    end
  end
end

counters = ~w(worldgen_chunks worldgen_microseconds column_persist_microseconds region_loads
              region_load_microseconds chunks_encoded chunk_encode_microseconds
              worldgen_wants worldgen_refreshes worldgen_dispatch_microseconds
              worldgen_terrain_jobs worldgen_decorate_jobs worldgen_full_jobs worldgen_alone_jobs)a

delta = fn before ->
  snapshot = Valimc.Metrics.snapshot()
  Map.new(counters, &{&1, Map.get(snapshot, &1, 0) - Map.get(before, &1, 0)})
end

view_at = fn x, z -> MapSet.new(ChunkView.chunks({Valimc.World.chunk_key(x, z), distance})) end

before = Valimc.Metrics.snapshot()
started = now.()
spawn_pose = :sys.get_state(pid).player

{client, first, full, have} =
  fill.(fill, client, view_at.(spawn_pose.x, spawn_pose.z), MapSet.new(), started, nil)

join = %{
  hop: 0,
  x: spawn_pose.x,
  z: spawn_pose.z,
  first_chunk_us: first,
  full_view_us: full,
  max_mailbox: peak.(),
  counters: delta.(before)
}

IO.puts(
  "join: first #{div(first, 1000)} ms, full #{div(full, 1000)} ms, mailbox #{join.max_mailbox} " <>
    inspect(join.counters)
)

{results, _, _} =
  Enum.reduce(1..hops, {[join], client, have}, fn hop, {results, client, have} ->
    x = spawn_pose.x + hop * hop_blocks
    z = spawn_pose.z
    before = Valimc.Metrics.snapshot()
    started = now.()
    :ok = Valimc.Connection.teleport(pid, %{x: x, y: 200.0, z: z, yaw: 0.0, pitch: 0.0})
    {client, first, full, have} = fill.(fill, client, view_at.(x, z), have, started, nil)
    mailbox = peak.()

    IO.puts(
      "hop #{hop} to x=#{x}: first #{div(first, 1000)} ms, full #{div(full, 1000)} ms, mailbox #{mailbox}"
    )

    {[
       %{
         hop: hop,
         x: x,
         z: z,
         first_chunk_us: first,
         full_view_us: full,
         max_mailbox: mailbox,
         counters: delta.(before)
       }
       | results
     ], client, have}
  end)

:gen_tcp.close(client.socket)

record = %{
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  seed: seed,
  view_distance: distance,
  hop_blocks: hop_blocks,
  schedulers: System.schedulers_online(),
  dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
  revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  scope:
    "One loopback TCP client acknowledging at 64 chunks per tick; server teleports into terrain no region has generated. Other host load is not controlled; see load_average.",
  load_average: System.cmd("sysctl", ["-n", "vm.loadavg"]) |> elem(0) |> String.trim(),
  hops: Enum.reverse(results)
}

File.mkdir_p!(Path.dirname(output))
File.write!(output, JSON.encode!(record))
