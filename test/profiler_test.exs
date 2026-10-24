defmodule Valimc.ProfilerTest do
  use ExUnit.Case, async: false
  # The application owns one capture, report retention and scheduler observations.
  @moduletag :tmp_dir
  alias Valimc.Admin.{Profiler, ProfileSampler, ProfileReport}
  alias Valimc.Commands.Source
  alias Valimc.Data.ProfileTicks

  setup %{tmp_dir: directory} do
    old = Application.fetch_env(:valimc, :profiler_path)
    Application.put_env(:valimc, :profiler_path, directory)
    Profiler.cancel()

    on_exit(fn ->
      Profiler.cancel()

      case old do
        {:ok, value} -> Application.put_env(:valimc, :profiler_path, value)
        :error -> Application.delete_env(:valimc, :profiler_path)
      end
    end)

    :ok
  end

  defp options(tokens \\ []) do
    {:ok, options} = Profiler.options(tokens)
    options
  end

  test "operator tree, greedy flags, and literal suggestions use the real dispatcher" do
    for level <- 0..2 do
      assert {:error, _} = Valimc.Commands.parse("spark profiler start", Source.parse_only(level))
      assert :binary.match(Valimc.Commands.graph_payload(level), "spark") == :nomatch
    end

    assert {:ok, {Valimc.Commands.Spark, :run}, args, _} =
             Valimc.Commands.parse(
               "spark profiler start --timeout 30 --process Valimc.World",
               Source.parse_only(3)
             )

    assert args[:literals] == ["profiler", "start"]
    assert args["options"] == "--timeout 30 --process Valimc.World"

    assert {_, _, suggestions} =
             Valimc.Commands.Suggestions.suggest("/spark profiler ", Source.parse_only(3))

    assert suggestions == ~w(cancel info open start stop)
  end

  test "all options are checked before starting and unknown Java flags are explicit errors" do
    assert options().timeout == 60

    for tokens <- [
          ~w(--timeout 0),
          ~w(--timeout 601),
          ~w(--interval 1),
          ~w(--interval 1001),
          ~w(--alloc),
          ~w(--timeout),
          ~w(--timeout 1 --timeout 2),
          ~w(--include-waiting --include-waiting)
        ] do
      assert {:error, _} = Profiler.options(tokens)
    end

    assert options(~w(--timeout 10 --interval 50 --process Valimc.World --include-waiting)) ==
             %{timeout: 10, interval: 50, process: "Valimc.World", include_waiting: true}

    assert Profiler.info() == nil
  end

  test "sampler sees a selected process, omits idle stacks by default and tolerates death" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Process.register(pid, Valimc.ProfilerFixture)
    on_exit(fn -> Process.exit(pid, :kill) end)
    now = System.monotonic_time(:millisecond)
    idle = ProfileSampler.new(options(~w(--process ProfilerFixture)))
    idle = Enum.reduce(1..20, idle, fn i, state -> ProfileSampler.sample(state, now + i) end)
    assert ProfileSampler.export(idle).observations == 0
    included = ProfileSampler.new(options(~w(--process ProfilerFixture --include-waiting)))

    included =
      Enum.reduce(1..20, included, fn i, state -> ProfileSampler.sample(state, now + i) end)

    data = ProfileSampler.export(included)
    assert data.observations > 0
    assert [%{pid: target}] = data.processes
    assert target == inspect(pid)
    assert Enum.all?(data.stacks, &(&1.name == "Valimc.ProfilerFixture"))
    Process.exit(pid, :kill)
    assert %{} = ProfileSampler.sample(included, now + 21)
  end

  test "duplicate start, cancel, stale timers, stop, exports and disk failure", %{tmp_dir: path} do
    assert {:ok, cancelled} = Profiler.start(options())
    assert {:error, _} = Profiler.start(options())
    assert :ok = Profiler.cancel()
    assert :error = Profiler.report(cancelled)
    send(Profiler, {:sample, cancelled})
    assert Profiler.info() == nil
    assert {:error, _} = Profiler.stop()
    assert {:ok, id} = Profiler.start(options())
    assert {:ok, ^id} = Profiler.stop()
    assert {:ok, %{status: "complete"}} = Profiler.report(id)
    json = File.read!(Path.join(path, id <> ".json")) |> :json.decode()
    assert json["kind"] == "profile"
    assert File.read!(Path.join(path, id <> ".html")) =~ "Call tree"
    assert :json.encode(Profiler.health())

    blocked = Path.join(path, "file")
    File.write!(blocked, "not a directory")
    Application.put_env(:valimc, :profiler_path, blocked)
    assert {:ok, retained} = Profiler.start(options())
    assert {:error, message} = Profiler.stop()
    assert message =~ Profiler.url(retained)
    assert {:ok, %{status: "complete"}} = Profiler.report(retained)
    assert Profiler.info() == nil
  end

  test "timeout saves and notifies once without a blocked command job" do
    parent = self()

    assert {:ok, id} =
             Profiler.start(options(~w(--timeout 1 --interval 10)), &send(parent, {:done, &1}))

    assert_receive {:done, {:ok, ^id}}, 15_000
    assert Profiler.info() == nil
    assert {:ok, %{rounds: rounds}} = Profiler.report(id)
    assert rounds > 0
    refute_receive {:done, _}, 30
  end

  test "running process reductions and stack capacity are measured independently" do
    pid = spawn(fn -> busy(0) end)
    Process.register(pid, Valimc.ProfilerBusyFixture)
    on_exit(fn -> Process.exit(pid, :kill) end)
    now = System.monotonic_time(:millisecond)
    state = ProfileSampler.new(options(~w(--process ProfilerBusyFixture)))
    state = Enum.reduce(1..30, state, fn i, acc -> ProfileSampler.sample(acc, now + i) end)
    exported = ProfileSampler.export(state)
    assert exported.observations > 0
    assert Enum.any?(exported.processes, &(&1.reductions > 0))
    full = Map.new(1..4096, &{{"fixture", [to_string(&1)]}, 1})
    state = %{state | stacks: full}
    state = Enum.reduce(1..30, state, fn i, acc -> ProfileSampler.sample(acc, now + 31 + i) end)
    assert state.dropped > 0
    assert map_size(state.stacks) == 4096
  end

  test "discovery covers large nodes even when pass counts wrap, and advances sparse batches" do
    large = Enum.to_list(1..12_800)

    {seen, _} =
      Enum.reduce(0..3, {MapSet.new(), 0}, fn i, {seen, cursor} ->
        {window, cursor} = ProfileSampler.window(large, cursor, if(i == 0, do: 0, else: 6400))
        {MapSet.union(seen, MapSet.new(window)), cursor}
      end)

    assert MapSet.size(seen) == 12_800
    sparse = Enum.to_list(1..400)

    {seen, _} =
      Enum.reduce(0..3, {MapSet.new(), 0}, fn i, {seen, cursor} ->
        {window, cursor} = ProfileSampler.window(sparse, cursor, if(i == 0, do: 0, else: 128))
        {MapSet.union(seen, MapSet.new(Enum.take(window, 128))), cursor}
      end)

    assert MapSet.size(seen) == 400
  end

  test "observer restart cancels captures but retains the live viewer port" do
    {:ok, id} = Profiler.start(options())
    viewer = Process.whereis(Valimc.Net.ProfileWeb)
    url = Profiler.url(id)
    assert :ok = Supervisor.terminate_child(Valimc.Infrastructure, Profiler)
    assert {:ok, _} = Supervisor.restart_child(Valimc.Infrastructure, Profiler)
    assert Profiler.info() == nil
    assert Profiler.url(id) == url
    assert Process.whereis(Valimc.Net.ProfileWeb) == viewer
    assert :error = Profiler.report(id)
    {:ok, fresh} = Profiler.health_report()
    assert request("/r/" <> fresh).status == 200
  end

  test "bounded report retention and token-only read-only HTTP routes" do
    {:ok, first} = Profiler.health_report()
    for _ <- 1..16, do: Profiler.health_report()
    assert :error = Profiler.report(first)
    {:ok, current} = Profiler.health_report()
    uri = URI.parse(Profiler.url(current))
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false], 2000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{uri.path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )

    reply = read_http(socket, [])
    assert reply =~ "200 OK"
    assert reply =~ "Call tree"
    assert reply =~ "frame-ancestors 'none'"
    json = request("/data/" <> current)
    assert json.status == 200
    assert :json.decode(json.resp_body)["status"] == "live"

    for path <- [
          "/",
          "/r/../../etc/passwd",
          "/r/" <> String.duplicate("0", 32),
          "/data/" <> current <> "/extra"
        ] do
      assert request(path).status == 404
    end
  end

  test "HTML payload cannot close its script or create markup" do
    html = ProfileReport.html(%{name: "</script><img src=x onerror=alert(1)> & \u2028"})
    refute html =~ "</script><img"
    assert html =~ "\\u003c/script\\u003e"
    assert html =~ "\\u2028"
    refute html =~ "__PROFILE_PAYLOAD__"
  end

  test "owner ticks, slow tick monitoring and RTT publications are observational" do
    parent = self()
    assert {:ok, true} = Profiler.monitor(self(), 9999, &send(parent, {:tick_notice, &1}))

    pid =
      spawn(fn ->
        # Synthetic duration avoids competing with real regions' occasional
        # slow ticks: monitoring deliberately aggregates the whole node.
        ProfileTicks.record(10_000_000_000, 3)
        ProfileTicks.rtt(self(), 7)
        send(parent, :recorded)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :recorded
    assert ProfileTicks.pings()[pid] == 7
    assert Enum.any?(ProfileTicks.snapshot(), &(elem(&1, 0) == pid))
    assert_receive {:tick_notice, notice}, 15_000
    assert notice =~ inspect(pid)
    assert notice =~ "3ms late"
    assert {:ok, false} = Profiler.monitor(self(), 9999, fn _ -> :ok end)
    Process.exit(pid, :kill)
    refute Map.has_key?(ProfileTicks.pings(), pid)
    refute Enum.any?(ProfileTicks.snapshot(), &(elem(&1, 0) == pid))
  end

  test "keepalive replies publish RTT and spark reports a bounded player summary" do
    before = System.monotonic_time(:millisecond) - 7
    state = %{connection: self(), keepalive: {123, before}}
    assert %{keepalive: nil} = Valimc.Session.Play.packet(state, "keep_alive", <<123::signed-64>>)
    assert ProfileTicks.pings()[self()] >= 7
    source = %{Source.parse_only(4) | sink: {:collect, self(), make_ref()}}
    Valimc.Commands.run(source, "spark ping")
    assert Source.collect(source) =~ "samples"
  end

  defp read_http(socket, acc) do
    case :gen_tcp.recv(socket, 0, 3000) do
      {:ok, bytes} -> read_http(socket, [acc, bytes])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp request(path) do
    Plug.Test.conn(:get, path) |> Valimc.Net.Profiler.Endpoint.call([])
  end

  defp busy(n), do: busy(:erlang.phash2({n, n + 1}))
end

defmodule Valimc.ProfilerConnectionTest do
  use ExUnit.Case, async: false
  # Operator commands and clickable URLs cross the real Minecraft socket path.
  @moduletag :tcp
  @moduletag :tmp_dir
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire

  test "profiling while playing returns a clickable viewer URL", %{tmp_dir: directory} do
    previous = Application.fetch_env(:valimc, :profiler_path)
    Application.put_env(:valimc, :profiler_path, directory)

    on_exit(fn ->
      case previous do
        {:ok, path} -> Application.put_env(:valimc, :profiler_path, path)
        :error -> Application.delete_env(:valimc, :profiler_path)
      end
    end)

    {_, client} = Client.login("Prof" <> Integer.to_string(System.unique_integer([:positive])))
    client = Client.load_world(client)

    on_exit(fn ->
      Client.close(client)
      Valimc.Admin.Profiler.cancel()
    end)

    Client.send_packet(
      client,
      :play,
      "chat_command",
      Wire.string("spark profiler start --timeout 30")
    )

    {body, client} = Client.await(client, :play, "system_chat")
    assert body =~ "Profiler is now running!"
    {_timeout, client} = Client.await(client, :play, "system_chat")
    {link, client} = Client.await(client, :play, "system_chat")
    assert link =~ "open_url"
    assert link =~ "http://127.0.0.1:"
    Client.send_packet(client, :play, "chat_command", Wire.string("spark profiler stop"))
    {body, client} = Client.await(client, :play, "system_chat")
    assert body =~ "Profiler stopped & save complete!"
    {link, _client} = Client.await(client, :play, "system_chat")
    assert link =~ "/r/"
  end
end
