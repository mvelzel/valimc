defmodule Valimc.Data.ProfileTicks do
  @moduledoc """
  Tick observations, written by each region to its own ETS row. No messages or
  profiler calls on the simulation path. The observer removes dead owners.
  """
  def init!, do: :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])

  def record(nanoseconds, late) do
    table = :ets.whereis(__MODULE__)

    if table != :undefined do
      pid = self()

      {count, total, maximum} =
        case :ets.lookup(table, pid) do
          [{_, count, total, maximum, _, _, _}] -> {count, total, maximum}
          [] -> {0, 0, 0}
        end

      :ets.insert(
        table,
        {pid, count + 1, total + nanoseconds, max(maximum, nanoseconds), nanoseconds, late,
         System.monotonic_time(:millisecond)}
      )

      if nanoseconds >= 10_000_000 do
        sequence = :ets.update_counter(table, :slow_sequence, {2, 1}, {:slow_sequence, 0})

        :ets.insert(
          table,
          {{:slow, rem(sequence, 256)}, sequence, inspect(pid), nanoseconds, late}
        )
      end
    end

    :ok
  end

  def slow_since(sequence) do
    for {{:slow, _}, seq, pid, ns, late} <- :ets.tab2list(__MODULE__),
        seq > sequence,
        do: %{sequence: seq, pid: pid, ms: ns / 1.0e6, late_ms: late}
  end

  def rtt(pid, milliseconds), do: :ets.insert(__MODULE__, {{:ping, pid}, milliseconds})

  def pings do
    for {{:ping, pid} = key, ms} <- :ets.tab2list(__MODULE__),
        if(Process.alive?(pid),
          do: true,
          else:
            (
              :ets.delete(__MODULE__, key)
              false
            )
        ),
        into: %{},
        do: {pid, ms}
  end

  def snapshot do
    for {pid, _, _, _, _, _, _} = row <- :ets.tab2list(__MODULE__),
        if(Process.alive?(pid),
          do: true,
          else:
            (
              :ets.delete(__MODULE__, pid)
              false
            )
        ),
        do: row
  end
end
