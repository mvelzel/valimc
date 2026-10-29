defmodule Valimc.ProfileWorkTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.{ProfileTicks, ProfileWork}

  test "sampled exclusive phases partition the complete callback, including nested commit work" do
    assert :result =
             ProfileWork.callback(:tick, fn ->
               ProfileWork.tick(fn ->
                 ProfileWork.workload(fn -> %{sections: 3, active_mobs: 29, ignored: :value} end)
                 ProfileWork.phase(:entities, fn -> Enum.sum(1..1000) end)

                 ProfileWork.phase(:lifecycle, fn ->
                   ProfileWork.phase(:commit_prepare, fn -> Enum.sum(1..1000) end)
                   :result
                 end)
               end)
             end)

    totals = ProfileWork.snapshot()[self()]
    assert totals.completed_ticks == 1
    assert totals.sampled_ticks == 1
    assert totals.workload == %{sections: 3, active_mobs: 29}
    assert totals.phases.commit_prepare.ns > 0
    assert totals.phases.lifecycle.ns > 0
    assert totals.phases.commit_prepare.calls == 1
    assert totals.callbacks.tick.ns == totals.sampled_ns
    assert Enum.sum(for {_, stats} <- totals.phases, do: stats.ns) == totals.sampled_ns
  end

  test "detailed coverage is first and every twentieth executed tick, not every callback" do
    for _ <- 1..41 do
      ProfileWork.callback(:player, fn -> :ok end)

      ProfileWork.callback(:tick, fn ->
        ProfileWork.tick(fn ->
          ProfileWork.workload(fn ->
            Process.put(:workload_reads, Process.get(:workload_reads, 0) + 1)
            %{active_mobs: 1}
          end)

          ProfileWork.phase(:entities, fn -> :ok end)
        end)
      end)
    end

    totals = ProfileWork.snapshot()[self()]
    assert totals.callbacks.player.calls == 41
    assert totals.callbacks.tick.calls == 41
    assert totals.completed_ticks == 41
    assert totals.sampled_ticks == 3
    assert totals.phases.entities.calls == 3
    assert Process.get(:workload_reads) == 3
    assert Enum.sum(for {_, stats} <- totals.phases, do: stats.ns) == totals.sampled_ns
  end

  test "callback durations fall into buckets that give interval percentiles" do
    for ms <- [1, 1, 1, 1, 1, 1, 1, 1, 1, 12] do
      ProfileWork.callback(:light, fn -> Process.sleep(ms) end)
    end

    stats = ProfileWork.snapshot()[self()].callbacks.light
    assert Enum.sum(Tuple.to_list(stats.buckets)) == 10
    assert %{p50_ms: p50, p99_ms: p99} = ProfileWork.percentiles(stats.buckets)
    assert p50 in [2.0, 3.0]
    assert p99 >= 15.0
    assert ProfileWork.percentiles(stats.buckets, stats.buckets).p95_ms == nil
  end

  test "exceptions and throws preserve behavior, restore phase context and do not complete ticks" do
    assert_raise ArgumentError, "fixture", fn ->
      ProfileWork.callback(:tick, fn ->
        ProfileWork.tick(fn ->
          ProfileWork.phase(:entities, fn -> raise ArgumentError, "fixture" end)
        end)
      end)
    end

    assert catch_throw(ProfileWork.callback(:player, fn -> throw(:fixture) end)) == :fixture
    assert :next = ProfileWork.callback(:generation, fn -> :next end)
    assert :plain = ProfileWork.phase(:entities, fn -> :plain end)
    totals = ProfileWork.snapshot()[self()]
    assert totals.completed_ticks == 0
    assert totals.sampled_ticks == 0
    assert totals.phases == %{}
    assert totals.callbacks.tick.calls == 1
    assert totals.callbacks.player.calls == 1
    assert totals.callbacks.generation.calls == 1
  end

  test "intervals have no invented warmup work, and zero coverage stays explicit" do
    ProfileWork.callback(:tick, fn ->
      ProfileWork.tick(fn -> ProfileWork.phase(:entities, fn -> :ok end) end)
    end)

    before = Map.take(ProfileWork.snapshot(), [self()])
    time = System.monotonic_time(:millisecond)
    id = inspect(self())
    assert ProfileWork.intervals(before, %{}, time)[id].completed_ticks == nil
    assert ProfileWork.intervals(before, %{}, time, :zero)[id].completed_ticks == 1
    ProfileWork.callback(:player, fn -> :ok end)
    after_work = Map.take(ProfileWork.snapshot(), [self()])
    interval = ProfileWork.intervals(after_work, before, time)[id]
    assert interval.completed_ticks == 0
    assert interval.sampled_ticks == 0
    assert interval.sampled_ms == 0.0
    assert interval.sampled_phases.entities.total_ms == 0.0
    assert interval.sampled_phases.entities.mean_ms == nil
    assert interval.callbacks.player.calls == 1
    assert interval.callbacks.player.total_ms > 0
    assert JSON.encode!(interval)
  end

  test "live owner work survives tick withdrawal, and dead rows are collected" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        ProfileWork.callback(:generation, fn -> :ok end)
        ProfileTicks.inactive()
        send(parent, :published)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :published
    assert ProfileWork.snapshot()[pid].callbacks.generation.calls == 1
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute Map.has_key?(ProfileWork.snapshot(), pid)
    assert :ets.lookup(ProfileTicks, {:work, pid}) == []
  end

  test "unknown tags execute normally without increasing observation cardinality" do
    for tag <- 1..100 do
      assert ^tag =
               ProfileWork.callback({:unknown, tag}, fn ->
                 ProfileWork.phase({:unknown, tag}, fn -> tag end)
               end)
    end

    totals = ProfileWork.snapshot()[self()]
    assert Map.keys(totals.callbacks) == [:other]
    assert totals.callbacks.other.calls == 100
    assert totals.phases == %{}
  end
end
