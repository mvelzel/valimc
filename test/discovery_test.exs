defmodule Valimc.ControlledDiscoveryFetch do
  def fetch(deadline) do
    send(
      Application.fetch_env!(:valimc, :discovery_test_owner),
      {:discovery_fetch, self(), deadline}
    )

    receive do
      {:fetch_result, result} -> result
    after
      5000 -> {:error, :fixture_timeout}
    end
  end
end

defmodule Valimc.DiscoveryTest do
  # Restarts the application's discovery owner.
  use ExUnit.Case, async: false
  alias Valimc.Net.Auth.{Discovery, DiscoveryDocument, DiscoverySupervisor, SessionService}
  @url "https://sessionserver.mojang.com/session/minecraft/hasJoined"
  defp deadline(ms \\ 2000), do: System.monotonic_time(:millisecond) + ms
  defp json(value), do: :json.encode(value) |> IO.iodata_to_binary()

  setup do
    previous =
      for key <- [:online_mode, :discovery_service, :discovery_test_owner],
          into: %{},
          do: {key, Application.get_env(:valimc, key)}

    Application.put_env(:valimc, :discovery_service, Valimc.ControlledDiscoveryFetch)
    Application.put_env(:valimc, :discovery_test_owner, self())
    restart(true)

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:valimc, key),
          else: Application.put_env(:valimc, key, value)
      end

      :ok = Supervisor.terminate_child(DiscoverySupervisor, Discovery)
      {:ok, _} = Supervisor.restart_child(DiscoverySupervisor, Discovery)
    end)

    :ok
  end

  defp restart(enabled) do
    :ok = Supervisor.terminate_child(DiscoverySupervisor, Discovery)
    Application.put_env(:valimc, :online_mode, enabled)
    {:ok, _} = Supervisor.restart_child(DiscoverySupervisor, Discovery)
    Application.put_env(:valimc, :online_mode, false)
  end

  defp eventually(fun, _budget \\ nil) do
    Valimc.TestWait.until(fun)
    :ok
  end

  defp accept(worker, route \\ @url) do
    send(worker, {:fetch_result, {:ok, route}})
    eventually(fn -> Discovery.publication().ready and :sys.get_state(Discovery).job == nil end)
  end

  test "route selection and unavailable, invalid or malformed documents" do
    doc = %{
      environment: "prod",
      product: "minecraft",
      discovery: %{session: %{endpoints: %{verify: %{uri: @url}}}}
    }

    assert {:ok, @url} = DiscoveryDocument.decode(json(doc))

    for value <- [
          %{doc | environment: "offline"},
          %{},
          %{discovery: %{session: %{endpoints: %{}}}},
          %{
            discovery: %{session: %{endpoints: %{verify: %{uri: "http://unsafe.invalid/verify"}}}}
          }
        ] do
      assert {:ok, nil} = DiscoveryDocument.decode(json(value))
    end

    for body <- [
          "not json",
          "{\"environment\":\"prod\",\"environment\":\"offline\"}",
          json(%{discovery: 42}),
          json(%{discovery: %{session: []}})
        ] do
      assert {:error, :invalid_discovery} = DiscoveryDocument.decode(body)
    end

    for value <- [
          %{environment: %{}},
          %{product: []},
          %{environment: "offline", discovery: 42},
          %{discovery: %{authentication: %{endpoints: %{other: %{uri: []}}}}},
          %{discovery: %{profiles: %{endpoints: %{other: %{validUris: [%{}]}}}}}
        ] do
      assert {:error, :invalid_discovery} = DiscoveryDocument.decode(json(value))
    end

    for uri <- [
          "http://unsafe.invalid/",
          "https://user:password@example.com/",
          "https://example.com/#fragment",
          "https://example.com/ bad",
          "https://example.com:99999/",
          String.duplicate("a", 2049)
        ] do
      refute DiscoveryDocument.valid_endpoint?(uri)
    end

    assert {:ok, url} = SessionService.url("OracleOne", "-abc", @url <> "?feature=current")

    assert URI.decode_query(URI.parse(url).query) == %{
             "feature" => "current",
             "username" => "OracleOne",
             "serverId" => "-abc"
           }
  end

  test "one initial fetch wakes parallel subscribers and supports protected concurrent reads" do
    assert_receive {:discovery_fetch, worker, _}
    parent = self()

    waiters =
      for _ <- 1..32,
          do: spawn(fn -> send(parent, {:endpoint, Discovery.endpoint(deadline())}) end)

    eventually(fn -> Registry.count(Valimc.Auth.DiscoveryWaiters) == 32 end)
    for _ <- 1..20, do: Discovery.refresh()
    refute_receive {:discovery_fetch, _, _}, 20
    accept(worker)
    for _ <- waiters, do: assert_receive({:endpoint, {:ok, @url}})
    eventually(fn -> Registry.count(Valimc.Auth.DiscoveryWaiters) == 0 end)
    assert {:ok, @url} = Discovery.endpoint(deadline())

    assert_raise ArgumentError, fn ->
      :ets.insert(Discovery, {:route, %{ready: true, endpoint: "https://forged.invalid"}})
    end

    assert :erlang.read_timer(:sys.get_state(Discovery).timer) in 86_390_000..86_400_000
  end

  test "initial failure completes readiness and follows native capped backoff" do
    for i <- 0..1 do
      assert_receive {:discovery_fetch, worker, _}
      send(worker, {:fetch_result, {:error, :unavailable}})
      eventually(fn -> :sys.get_state(Discovery).job == nil end)
      state = :sys.get_state(Discovery)
      expected = 60_000 * Integer.pow(2, i)
      assert :erlang.read_timer(state.timer) in (expected - 1000)..expected
      assert Discovery.endpoint(deadline()) == {:error, :discovery_unavailable}
      if i < 1, do: Discovery.refresh()
    end

    for i <- 0..10,
        do: assert(DiscoveryDocument.retry_delay(false, i) == 60_000 * Integer.pow(2, min(i, 6)))

    assert DiscoveryDocument.retry_delay(true, 6) == 86_400_000
  end

  test "cached document survives refresh failure; successful unavailable publication clears routing" do
    assert_receive {:discovery_fetch, worker, _}
    accept(worker)
    Discovery.refresh()
    assert_receive {:discovery_fetch, worker, _}
    assert {:ok, @url} = Discovery.endpoint(deadline())
    send(worker, {:fetch_result, {:error, :invalid_discovery}})
    eventually(fn -> :sys.get_state(Discovery).job == nil end)
    assert {:ok, @url} = Discovery.endpoint(deadline())
    assert :erlang.read_timer(:sys.get_state(Discovery).timer) in 86_390_000..86_400_000
    Discovery.refresh()
    assert_receive {:discovery_fetch, worker, _}
    accept(worker, nil)
    assert {:error, :discovery_unavailable} = Discovery.endpoint(deadline())
    Discovery.refresh()
    assert_receive {:discovery_fetch, worker, _}
    accept(worker, "https://new.example/verify")
    assert {:ok, "https://new.example/verify"} = Discovery.endpoint(deadline())
  end

  test "subscriber deadlines and abrupt death release registrations" do
    assert_receive {:discovery_fetch, worker, _}
    assert {:error, :discovery_unavailable} = Discovery.endpoint(deadline(20))
    assert Registry.count(Valimc.Auth.DiscoveryWaiters) == 0
    waiting = spawn(fn -> Discovery.endpoint(deadline()) end)
    eventually(fn -> Registry.count(Valimc.Auth.DiscoveryWaiters) == 1 end)
    Process.exit(waiting, :kill)
    eventually(fn -> Registry.count(Valimc.Auth.DiscoveryWaiters) == 0 end)
    accept(worker)
    assert {:error, :discovery_unavailable} = Discovery.endpoint(deadline(-1))
  end

  test "stale timers/results and late valid documents cannot overwrite a cached route" do
    assert_receive {:discovery_fetch, worker, _}
    accept(worker)
    old = :sys.get_state(Discovery).generation
    Discovery.refresh()
    assert_receive {:discovery_fetch, worker, _}
    state = :sys.get_state(Discovery)
    send(Discovery, {:refresh, old})
    send(Discovery, {:discovery_result, self(), make_ref(), {:ok, "https://forged.example/"}})
    send(Discovery, {:DOWN, make_ref(), :process, self(), :normal})
    send(Discovery, {:discovery_deadline, state.job.token})
    assert :sys.get_state(Discovery).job.pid == worker
    :sys.replace_state(Discovery, fn s -> %{s | job: %{s.job | deadline: deadline(-1)}} end)
    send(worker, {:fetch_result, {:ok, "https://late.example/"}})
    eventually(fn -> :sys.get_state(Discovery).job == nil end)
    assert {:ok, @url} = Discovery.endpoint(deadline())
  end

  test "worker failure unblocks initial readiness and releases its job" do
    assert_receive {:discovery_fetch, worker, _}
    Process.exit(worker, :kill)
    eventually(fn -> Discovery.publication().ready end)
    assert :sys.get_state(Discovery).job == nil
    assert {:error, :discovery_unavailable} = Discovery.endpoint(deadline())
  end

  test "owner loss cancels its fetch and waiting subscribers" do
    assert_receive {:discovery_fetch, worker, _}
    parent = self()
    spawn(fn -> send(parent, {:waiting_result, Discovery.endpoint(deadline())}) end)
    eventually(fn -> Registry.count(Valimc.Auth.DiscoveryWaiters) == 1 end)
    ref = Process.monitor(worker)
    old = Process.whereis(Discovery)
    Application.put_env(:valimc, :online_mode, true)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert_receive {:waiting_result, {:error, :discovery_unavailable}}
    assert_receive {:discovery_fetch, new_worker, _}
    Application.put_env(:valimc, :online_mode, false)
    refute new_worker == worker
    accept(new_worker)
  end

  test "offline startup and refresh perform no external fetch" do
    assert_receive {:discovery_fetch, _, _}
    restart(false)
    assert Discovery.publication().ready
    Discovery.refresh()
    refute_receive {:discovery_fetch, _, _}, 30
    assert :sys.get_state(Discovery).job == nil
    assert {:error, :discovery_unavailable} = Discovery.endpoint(deadline())
  end
end
