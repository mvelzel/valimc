defmodule Valimc.ProfilerTickRatesTest do
  use ExUnit.Case, async: true
  alias Valimc.Admin.Profiler
  alias Valimc.Net.Profiler.View
  @running %{rate: 20.0, frozen: false, sprinting: false}

  test "a healthy clock cannot hide the slowest owner's completed simulation ticks" do
    slow = self()
    fast = make_ref()
    rows = [row(slow, 105, 1_000_000_000), row(fast, 120, 100_000_000)]
    previous = %{slow => {100, 0}, fast => {100, 0}}
    owners = Profiler.tick_rates(rows, previous, 1000, 1000)
    assert [%{tps: 5.0, mean_ms: 200.0}, %{tps: 20.0}] = owners
    assert Profiler.simulation_tps(owners, @running) == 5.0
  end

  test "a living stalled owner contributes zero even while its previous duration is stale" do
    owners = Profiler.tick_rates([row(self(), 100, 1000)], %{self() => {100, 1000}}, 5000, 1000)
    assert [%{tps: rate, mean_ms: nil, age_ms: 4000}] = owners
    assert rate == 0.0
    assert Profiler.simulation_tps(owners, @running) == 0.0
  end

  test "warmup and owner replacement have no invented zero or clock fallback" do
    assert Profiler.simulation_tps([], @running) == nil
    replacement = Profiler.tick_rates([row(self(), 7, 1000)], %{}, 1000, 1000)
    assert [%{tps: nil, mean_ms: nil}] = replacement
    assert Profiler.simulation_tps(replacement, @running) == nil
    measured = Profiler.tick_rates([row(self(), 9, 3000)], %{self() => {7, 1000}}, 2000, 1000)
    assert Profiler.simulation_tps(measured, @running) == 2.0
  end

  test "normal TPS caps sampling jitter at the configured rate; sprints retain actual progress" do
    assert Profiler.simulation_tps([%{tps: 21.0}], @running) == 20.0
    assert Profiler.simulation_tps([%{tps: 500.0}], %{@running | sprinting: true}) == 500.0
    assert Profiler.simulation_tps([%{tps: 0.0}], %{@running | frozen: true}) == 0.0
  end

  test "rolling rates weight elapsed time, skip warmup and include complete stalls" do
    points = [point(5000, 1000, nil), point(4000, 3000, 4.0), point(1000, 1000, 20.0)]
    [window | _] = Profiler.windows(points)
    assert window.tps == 8.0
    assert window.clock_tps == 20.0
    [stalled | _] = Profiler.windows([point(5000, 1000, 0.0) | tl(points)])
    assert_in_delta stalled.tps, 6.4, 0.001
    assert hd(Profiler.windows([])).tps == nil
    assert hd(Profiler.windows([point(1000, 1000, nil)])).tps == nil
  end

  test "charts preserve stalls, missing observations and actual elapsed spacing" do
    data = %{
      history: [
        %{at: 0, tps: 20.0, mspt: %{p95: 50.0}},
        %{at: 1000, tps: 5.0, mspt: %{p95: 200.0}},
        %{at: 2000, tps: nil},
        %{at: 4000, tps: 0.0, mspt: %{p95: 200.0}}
      ]
    }

    assert coordinates(View.chart(data)) == [
             {"M", 0.0, 20.0},
             {"L", 300.0, 132.5},
             {"M", 1200.0, 170.0}
           ]

    assert View.chart_max(data, :mspt) == 200.0

    assert coordinates(View.chart(data, :mspt)) == [
             {"M", 0.0, 132.5},
             {"L", 300.0, 20.0},
             {"M", 1200.0, 20.0}
           ]
  end

  test "legacy clock history is never renamed as simulation progress" do
    legacy = %{health: %{tps: 20.0}}
    assert View.tps_title(legacy) == "Clock TPS (legacy)"
    assert View.tps_caption(legacy) =~ "not recorded"
    assert View.tps_title(%{health: %{tps_source: "simulation"}}) == "Simulation TPS"
  end

  defp row(pid, count, total), do: {pid, count, total, 200_000_000, 200_000_000, 150, 1000}

  defp coordinates(path) do
    for [command, x, y] <- Regex.scan(~r/([ML])([^, ]+),([^ ]+)/, path, capture: :all_but_first),
        do: {command, String.to_float(x), String.to_float(y)}
  end

  defp point(at, elapsed, tps),
    do: %{
      at: at,
      interval_ms: elapsed,
      tps: tps,
      clock_tps: 20.0,
      scheduler: %{normal: 50.0, dirty_cpu: 0.0, dirty_io: 0.0}
    }
end
