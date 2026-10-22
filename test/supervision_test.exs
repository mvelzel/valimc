defmodule Valimc.SupervisionTest do
  # Kills the global listener and stopwatch owner: not concurrent with socket suites.
  # (Not the clock: a restarted clock forgets the suite's natural-regeneration switch.)
  use ExUnit.Case, async: false

  test "accept errors back off and the acceptor keeps accepting" do
    replies = [
      {:error, :emfile},
      {:error, :enfile},
      {:error, :system_limit},
      {:error, :econnaborted},
      {:ok, :socket},
      {:error, :closed}
    ]

    {:ok, script} = Agent.start_link(fn -> replies end)
    accept = fn -> Agent.get_and_update(script, fn [reply | rest] -> {reply, rest} end) end
    test = self()
    started = System.monotonic_time(:millisecond)

    assert Valimc.Net.Listener.accept_loop(accept, &send(test, {:started, &1})) == :ok
    assert_received {:started, :socket}
    # 10 + 20 + 40 + 80 ms of back-off.
    assert System.monotonic_time(:millisecond) - started >= 150
  end

  test "a crash loop of one owner stays inside its domain" do
    others = Enum.map([Valimc.ConnectionSupervisor, Valimc.RegionSupervisor], &Process.whereis/1)

    # Four crashes within seconds stopped the application under the old flat root (3 in 5 s).
    for name <- [Valimc.Net.Listener, Valimc.World.Stopwatches], _ <- 1..4 do
      pid = Process.whereis(name)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      Valimc.TestWait.until(fn -> Process.whereis(name) not in [nil, pid] end)
    end

    assert Enum.map([Valimc.ConnectionSupervisor, Valimc.RegionSupervisor], &Process.whereis/1) ==
             others

    assert is_integer(Valimc.Net.Listener.port())
  end
end
