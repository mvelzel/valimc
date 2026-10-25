defmodule Valimc.ProfilerLiveTest do
  use ExUnit.Case, async: false
  # One application-owned capture and admission pool; LiveViews read its snapshots.
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Valimc.Admin.Profiler
  alias Valimc.Net.Profiler.{Limits, View}
  @endpoint Valimc.Net.Profiler.Endpoint

  setup do
    Profiler.cancel()
    on_exit(fn -> Profiler.cancel() end)
    :ok
  end

  defp capture do
    {:ok, options} = Profiler.options(~w(--include-waiting --interval 10))
    {:ok, id} = Profiler.start(options)
    # Drive a sampler publication, independently of host scheduling delays.
    send(Profiler, {:sample, id})
    send(Profiler, :health)
    Profiler.info()
    id
  end

  test "dashboard and exports distinguish slow simulation from a healthy world clock" do
    id = capture()
    assert {:ok, ^id} = Profiler.stop()
    {:ok, data} = Profiler.report(id)

    health = %{
      data.health
      | tps: 5.0,
        clock_tps: 20.0,
        tps_source: "simulation",
        windows: [%{seconds: 5, tps: 5.0, clock_tps: 20.0, scheduler: data.health.scheduler}]
    }

    :sys.replace_state(Profiler, fn state ->
      :ets.insert(Valimc.ProfileReports, {id, %{data | health: health}})
      state
    end)

    {:ok, view, _} = live(build_conn(), "/r/" <> id)
    assert has_element?(view, ".stat", "Simulation TPS")
    assert render(view) =~ "Slowest region"
    render_click(view, "tab", %{"tab" => "health"})
    assert has_element?(view, "h2", "Simulation TPS over time")
    assert has_element?(view, "h2", "Region p95 MSPT over time")
    assert render(view) =~ "World clock TPS (separate)"
    html = get(build_conn(), "/export/#{id}/html").resp_body
    assert html =~ "Simulation TPS"
    assert html =~ "Clock TPS (legacy)"
    assert html =~ "Region p95 MSPT over time"
  end

  test "real LiveView filters, expands, switches views, sorts, zooms and preserves state on refresh" do
    id = capture()
    {:ok, view, html} = live(build_conn(), "/r/" <> id)
    assert html =~ "data-phx-session"
    assert has_element?(view, ".brand", "ValiMC")
    refute html =~ "class=\"bolt\""
    assert has_element?(view, ".tree-row")
    # Select by the rendered, server-validated ID rather than inventing a path.
    [id | _] =
      Regex.scan(~r/phx-value-id="([a-f0-9]+)"/, html, capture: :all_but_first) |> List.flatten()

    render_click(view, "expand", %{"id" => id})
    assert has_element?(view, "[aria-expanded=true]")
    render_click(view, "tab", %{"tab" => "flame"})
    assert has_element?(view, "#flame rect")
    view |> element("#flame g:nth-child(2) rect") |> render_click()
    assert has_element?(view, "#reset-zoom")
    view |> element("#reset-zoom") |> render_click()

    for {tab, _} <- View.tabs() do
      render_click(view, "tab", %{"tab" => tab})
      assert has_element?(view, "#tabs button[aria-selected=true][phx-value-tab=#{tab}]")
    end

    render_click(view, "tab", %{"tab" => "processes"})
    view |> element("th button[phx-value-key=memory]") |> render_click()
    assert render(view) =~ "↓"
    view |> element("th button[phx-value-key=memory]") |> render_click()
    assert render(view) =~ "↑"
    view |> form("#filters", %{query: "Valimc", group: ""}) |> render_change()
    assert has_element?(view, "#query[value=Valimc]")
    send(view.pid, :refresh)
    assert render(view) =~ "Valimc"
    assert has_element?(view, "#tabs button[aria-selected=true][phx-value-tab=processes]")
    render_click(view, "theme")
    assert has_element?(view, "#profile-report[data-theme=light]")
    render_click(view, "filter", %{"query" => String.duplicate("x", 129), "group" => ""})
    render_click(view, "filter", %{"query" => %{"unexpected" => "object"}, "group" => ""})
    render_click(view, "sort", %{"key" => "not-an-atom"})
    render_click(view, "tab", %{"tab" => "not-a-view"})
    assert has_element?(view, "#query[value=Valimc]")
  end

  test "tokens expire closed on HTTP and on an already connected viewer" do
    id = capture()
    {:ok, view, _} = live(build_conn(), "/r/" <> id)
    Profiler.cancel()
    assert get(build_conn(), "/r/" <> id).status == 404
    send(view.pid, :refresh)
    assert render(view) =~ "Report expired"
    assert render_click(view, "tab", %{"tab" => "processes"}) =~ "Report expired"
    assert get(build_conn(), "/data/" <> String.duplicate("0", 32)).status == 404
  end

  test "local packaged assets, signed mount, CSP and offline attachments" do
    id = capture()
    conn = get(build_conn(), "/r/" <> id)
    assert conn.resp_body =~ "/assets/app.js"

    forged = %{
      conn
      | resp_body:
          Regex.replace(
            ~r/data-phx-session="[^"]+"/,
            conn.resp_body,
            "data-phx-session=\"invalid\""
          )
    }

    assert {:error, _} = live(forged)

    assert Plug.Conn.get_resp_header(conn, "content-security-policy") |> hd() =~
             "script-src 'self'"

    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

    for path <-
          ~w(/assets/app.js /assets/style.css /assets/fonts/JetBrainsMono-Regular.woff2 /assets/phoenix/phoenix.mjs /assets/live/phoenix_live_view.esm.js) do
      assert get(build_conn(), path).status == 200
    end

    json = get(build_conn(), "/export/#{id}/json")
    assert :json.decode(json.resp_body)["kind"] == "profile"

    assert Plug.Conn.get_resp_header(json, "content-disposition") == [
             "attachment; filename=\"valimc-profile.json\""
           ]

    html = get(build_conn(), "/export/#{id}/html").resp_body
    assert html =~ "data:font/woff2;base64,"
    assert html =~ "\"endpoint\":null"
    assert html =~ "\"status\":\"snapshot\""
    refute html =~ "__PROFILE_STYLE__"
    refute html =~ "src=\"/assets/"
    assert get(build_conn(), "/export/#{id}/other").status == 404
  end

  test "WebSocket upgrades reject foreign origins and missing CSRF sessions" do
    {:ok, id} = Profiler.health_report()
    port = URI.parse(Profiler.url(id)).port
    html = get(build_conn(), "/r/" <> id).resp_body
    [_, root] = Regex.run(~r/id="(phx-[^"]+)"/, html)
    [_, token] = Regex.run(~r/data-phx-session="([^"]+)"/, html)
    [_, static] = Regex.run(~r/data-phx-static="([^"]+)"/, html)

    ExUnit.CaptureLog.capture_log(fn ->
      for origin <- ["https://example.invalid", "http://127.0.0.1:#{port}"] do
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2000)
        on_exit(fn -> :gen_tcp.close(socket) end)

        :ok =
          :gen_tcp.send(socket, [
            "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\nHost: 127.0.0.1:",
            to_string(port),
            "\r\nOrigin: ",
            origin,
            "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
          ])

        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 2000)

        if origin == "https://example.invalid" do
          assert reply =~ "403"
        else
          # Phoenix accepts the transport, then rejects the signed LiveView
          # mount because connect_info.session is nil without cookie + CSRF.
          assert reply =~ "101 Switching Protocols"

          payload =
            JSON.encode!([
              "1",
              "1",
              "lv:" <> root,
              "phx_join",
              %{
                "session" => token,
                "static" => static,
                "params" => %{},
                "url" => Profiler.url(id)
              }
            ])

          mask = :crypto.strong_rand_bytes(4)

          masked =
            for {byte, i} <- payload |> :binary.bin_to_list() |> Enum.with_index(),
                into: <<>>,
                do: <<:erlang.bxor(byte, :binary.at(mask, rem(i, 4)))>>

          :ok =
            :gen_tcp.send(
              socket,
              <<0x81, 0xFE, byte_size(payload)::16, mask::binary, masked::binary>>
            )

          assert {:ok, result} = :gen_tcp.recv(socket, 0, 2000)
          assert result =~ ~s("reason":"stale")
        end
      end
    end)
  end

  test "admission admits 16 views and releases a dead view's slot" do
    pids =
      for _ <- 1..17,
          do:
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)
    for pid <- Enum.take(pids, 16), do: assert(Limits.admit(pid) == :ok)
    assert Limits.admit(hd(pids)) == :ok
    assert Limits.admit(List.last(pids)) == :full
    Process.exit(hd(pids), :kill)
    # Synchronize with the monitor notification, then retry the actual admission.
    ref = Process.monitor(hd(pids))
    assert_receive {:DOWN, ^ref, _, _, _}
    :sys.get_state(Limits)
    assert Limits.admit(List.last(pids)) == :ok
  end

  test "hosted reports advertise HTTPS and permit only the configured public WebSocket origin" do
    previous_url = Application.fetch_env(:valimc, :profiler_url)
    previous_endpoint = Application.fetch_env!(:valimc, @endpoint)
    endpoint = Keyword.put(previous_endpoint, :check_origin, ["https://valimc.fly.dev"])
    Application.put_env(:valimc, :profiler_url, "https://valimc.fly.dev")
    Application.put_env(:valimc, @endpoint, endpoint)
    @endpoint.config_change([{@endpoint, endpoint}], [])

    on_exit(fn ->
      case previous_url do
        {:ok, value} -> Application.put_env(:valimc, :profiler_url, value)
        :error -> Application.delete_env(:valimc, :profiler_url)
      end

      Application.put_env(:valimc, @endpoint, previous_endpoint)
      @endpoint.config_change([{@endpoint, previous_endpoint}], [])
    end)

    {:ok, id} = Profiler.health_report()
    assert Profiler.url(id) == "https://valimc.fly.dev/r/#{id}"
    conn = get(build_conn(), "/r/#{id}")
    csp = conn |> Plug.Conn.get_resp_header("content-security-policy") |> hd()
    assert csp =~ "wss://valimc.fly.dev"
    refute csp =~ "ws://localhost"
    assert get(build_conn(), "/healthz").resp_body == "ok\n"
    assert get(build_conn(), "/r/" <> String.duplicate("0", 32)).status == 404
    {:ok, {_, port}} = @endpoint.server_info(:http)

    ExUnit.CaptureLog.capture_log(fn ->
      for {origin, status} <- [
            {"https://valimc.fly.dev", "101 Switching Protocols"},
            {"https://foreign.invalid", "403"},
            {"http://valimc.fly.dev", "403"}
          ] do
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2000)

        :ok =
          :gen_tcp.send(socket, [
            "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\nHost: valimc.fly.dev\r\nOrigin: ",
            origin,
            "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
          ])

        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 2000)
        :gen_tcp.close(socket)
        assert reply =~ status
      end
    end)
  end

  test "endpoint restart retains captures and republishes its actual ephemeral port" do
    id = capture()
    assert :ok = Supervisor.terminate_child(Valimc.Net.ProfileWeb, @endpoint)
    assert {:ok, _} = Supervisor.restart_child(Valimc.Net.ProfileWeb, @endpoint)
    {:ok, {_, port}} = @endpoint.server_info(:http)
    assert URI.parse(Profiler.url(id)).port == port
    assert {:ok, _} = Profiler.report(id)
    assert get(build_conn(), "/r/" <> id).status == 200
  end

  test "presentation bounds render rows and escapes hostile process names" do
    stacks = for n <- 1..4096, do: %{path: ["owner#{n}", "</script>"], count: 1}
    assert length(View.tree(stacks, MapSet.new())) == 1000
    assert length(View.flame(stacks, nil)) <= 2000
    assert View.format(nil, :number) == "—"
    assert Profiler.median([1.0, 3.0]) == 2.0
    assert Profiler.median([1.0, 2.0, 3.0]) == 2.0

    windows =
      Profiler.windows([
        %{at: 20_000, tps: 20.0, scheduler: %{normal: 10.0, dirty_cpu: 0.0, dirty_io: 0.0}},
        %{at: 10_000, tps: 10.0, scheduler: %{normal: 30.0, dirty_cpu: 0.0, dirty_io: 0.0}}
      ])

    assert hd(windows).tps == 20.0
    assert Enum.at(windows, 2).tps == 15.0
  end
end

defmodule Valimc.SparkStyleTest do
  use ExUnit.Case, async: true
  alias Valimc.Commands.SparkStyle, as: Style
  alias Valimc.Text

  test "spark prefix, emphasis, statistic colors, clickable prompts and gray URLs" do
    prefix = Text.to_json(Style.prefix("TPS"))
    assert prefix["color"] == "gray"

    assert [
             %{"text" => "[", "color" => "dark_gray"},
             %{"text" => "⚡", "color" => "yellow", "bold" => true} | _
           ] = prefix["extra"]

    assert Text.plain(Style.prefix("TPS")) == "[⚡] TPS"

    for {value, color} <- [{20.0, "green"}, {17.0, "yellow"}, {15.0, "red"}] do
      assert Text.to_json(Style.tps(value, 20.0))["color"] == color
    end

    assert Text.plain(Style.tps(20.3, 20.0)) == "*20.0"
    assert Text.plain(Style.tps(nil, 20.0)) == "unavailable"
    assert Text.to_json(Style.duration(50))["color"] == "red"
    assert Text.to_json(Style.utilization(70))["color"] == "yellow"
    assert Text.to_json(Style.url("http://localhost"))["color"] == "gray"
    refute Text.to_json(Style.url("http://localhost"))["underlined"]

    assert Text.to_json(Style.prompt("/spark profiler stop"))["extra"]
           |> hd()
           |> Map.fetch!("click_event") == %{
             "action" => "run_command",
             "command" => "/spark profiler stop"
           }
  end
end
