defmodule Valimc.Data.ProfileWork do
  @moduledoc """
  Bounded owner wall-time observations. Every callback records its full duration;
  the first and every twentieth executed tick also partitions time into exclusive
  phases. Native waits and GC within a phase are included, not separate CPU time.
  One ETS row per owner; no observer messages on the gameplay path.
  """
  alias Valimc.Data.ProfileTicks
  @context {__MODULE__, :context}
  @totals {__MODULE__, :totals}
  @ticks {__MODULE__, :ticks}
  @callbacks [
    :tick,
    :commit,
    :player,
    :generation,
    :light,
    :transfer,
    :call,
    :resource,
    :gc,
    :load,
    :other
  ]
  @phases [
    :overhead,
    :tracking,
    :spawning,
    :arena,
    :blocks,
    :events,
    :entities,
    :pistons,
    :hoppers,
    :cooking,
    :lifecycle,
    :transfers,
    :commit_prepare,
    :workload
  ]
  @counts [
    :sections,
    :loaded_chunks,
    :active_chunks,
    :loaded_entities,
    :active_mobs,
    :hosted_players
  ]
  @empty %{
    callbacks: %{},
    phases: %{},
    completed_ticks: 0,
    sampled_ticks: 0,
    sampled_ns: 0,
    workload: nil,
    workload_at: nil
  }

  def callback(kind, fun) when kind in @callbacks do
    # Owner dispatch does not nest; an inline call retains the outer callback.
    if Process.get(@context) do
      fun.()
    else
      started = now()

      Process.put(@context, %{
        kind: kind,
        started: started,
        stamp: started,
        phase: :overhead,
        sampled: false,
        completed: false,
        phases: %{},
        workload: nil,
        workload_at: nil
      })

      try do
        fun.()
      after
        finish()
      end
    end
  end

  def callback(_kind, fun), do: callback(:other, fun)

  @doc "Mark an executed simulation tick, with bounded detailed sampling."
  def tick(fun) do
    count = Process.get(@ticks, 0) + 1
    Process.put(@ticks, count)
    update(&%{&1 | sampled: rem(count - 1, 20) == 0})
    result = fun.()
    update(&%{&1 | completed: true})
    result
  end

  def phase(kind, fun) when kind in @phases do
    case Process.get(@context) do
      %{sampled: true, phase: previous} ->
        switch(kind, true)

        try do
          fun.()
        after
          switch(previous, false)
        end

      _ ->
        fun.()
    end
  end

  # An additional gameplay phase stays accounted in its enclosing phase until
  # it gets a named observation; instrumentation must not reject new work.
  def phase(_kind, fun), do: fun.()

  @doc "Evaluate workload counts only on a detailed sample."
  def workload(fun) do
    case Process.get(@context) do
      %{sampled: true} ->
        at = System.monotonic_time(:millisecond)
        counts = phase(:workload, fn -> Map.take(fun.(), @counts) end)
        update(&%{&1 | workload: counts, workload_at: at})

      _ ->
        :ok
    end
  end

  def snapshot do
    case :ets.whereis(ProfileTicks) do
      :undefined ->
        %{}

      table ->
        rows = :ets.match_object(table, {{:work, :_}, :_})

        for {{:work, pid} = key, value} <- rows,
            if(Process.alive?(pid),
              do: true,
              else:
                (
                  :ets.delete(table, key)
                  false
                )
            ),
            into: %{},
            do: {pid, value}
    end
  end

  @doc "Per-owner interval deltas; detailed phases cover sampled ticks only."
  def intervals(current, previous, time, missing \\ :warmup) do
    Map.new(current, fn {pid, totals} ->
      old = Map.get(previous, pid, if(missing == :zero, do: @empty))

      value = %{
        warmed_up: old != nil,
        callbacks: deltas(totals.callbacks, old && old.callbacks, time),
        sampled_phases: deltas(totals.phases, old && old.phases, time),
        completed_ticks: delta(totals, old, :completed_ticks),
        sampled_ticks: delta(totals, old, :sampled_ticks),
        sampled_ms: divided(delta(totals, old, :sampled_ns)),
        workload: totals.workload,
        workload_age_ms: if(totals.workload_at, do: max(0, time - totals.workload_at))
      }

      {inspect(pid), value}
    end)
  end

  defp deltas(current, previous, time) do
    Map.new(current, fn {kind, stats} ->
      old = previous && Map.get(previous, kind, %{calls: 0, ns: 0})
      calls = if old, do: stats.calls - old.calls
      ns = if old, do: stats.ns - old.ns

      {kind,
       %{
         calls: calls,
         total_ms: divided(ns),
         mean_ms: if(is_number(calls) and calls > 0, do: ns / calls / 1.0e6),
         last_ms: stats.last / 1.0e6,
         last_age_ms: max(0, time - stats.at),
         lifetime_max_ms: stats.maximum / 1.0e6
       }}
    end)
  end

  defp delta(_current, nil, _key), do: nil
  defp delta(current, previous, key), do: current[key] - previous[key]
  defp divided(nil), do: nil
  defp divided(ns), do: ns / 1.0e6

  defp switch(kind, count?) do
    time = now()
    context = Process.get(@context) |> charge(time)
    phases = if count?, do: add_call(context.phases, kind), else: context.phases
    Process.put(@context, %{context | stamp: time, phase: kind, phases: phases})
  end

  defp charge(context, time) do
    phases =
      Map.update(
        context.phases,
        context.phase,
        %{calls: 0, ns: time - context.stamp},
        &%{&1 | ns: &1.ns + time - context.stamp}
      )

    %{context | phases: phases}
  end

  defp add_call(phases, kind),
    do: Map.update(phases, kind, %{calls: 1, ns: 0}, &%{&1 | calls: &1.calls + 1})

  defp finish do
    time = now()
    context = Process.delete(@context)
    elapsed = time - context.started
    totals = Process.get(@totals, @empty)
    callbacks = add(totals.callbacks, context.kind, 1, elapsed)

    totals = %{
      totals
      | callbacks: callbacks,
        completed_ticks: totals.completed_ticks + if(context.completed, do: 1, else: 0)
    }

    totals =
      if context.sampled and context.completed do
        context = charge(context, time)

        phases =
          Enum.reduce(context.phases, totals.phases, fn {kind, stats}, acc ->
            add(acc, kind, stats.calls, stats.ns)
          end)

        %{
          totals
          | phases: phases,
            sampled_ticks: totals.sampled_ticks + 1,
            sampled_ns: totals.sampled_ns + elapsed,
            workload: context.workload,
            workload_at: context.workload_at
        }
      else
        totals
      end

    Process.put(@totals, totals)

    if :ets.whereis(ProfileTicks) != :undefined,
      do: :ets.insert(ProfileTicks, {{:work, self()}, totals})
  end

  defp add(stats, kind, calls, ns) do
    at = System.monotonic_time(:millisecond)

    Map.update(stats, kind, %{calls: calls, ns: ns, last: ns, maximum: ns, at: at}, fn old ->
      %{
        calls: old.calls + calls,
        ns: old.ns + ns,
        last: ns,
        maximum: max(old.maximum, ns),
        at: at
      }
    end)
  end

  defp update(fun) do
    if context = Process.get(@context), do: Process.put(@context, fun.(context))
    :ok
  end

  defp now, do: System.monotonic_time(:nanosecond)
end
