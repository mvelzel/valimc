defmodule Valimc.FileBudget do
  @moduledoc """
  A bound on the files ValiMC's durability logs hold open at once (VMC-074).

  Region stores, proto owners and player logs (`Valimc.World.RegionLog`) open
  a file only for one operation (an append with its sync, a read, a checkpoint)
  and close it again, each inside `with_files/2`, which takes descriptors from
  this budget first. However many regions are loaded, the logs then hold at most
  `cap/0` descriptors, so sockets and the runtime keep the rest of the process's
  limit.

  At start (`init!/0`) the soft `RLIMIT_NOFILE` is raised toward the hard
  limit as the JVM does for vanilla (macOS starts processes at 256, at most
  `OPEN_MAX` 10240), and the cap is half of what remains after a reserve for
  sockets and the runtime, between 8 and 1024 (`:open_files_budget` overrides
  it). The budget is an atomic counter, not a process: a caller that finds it
  full backs off and tries again.

  Running out of descriptors anyway (other processes, a lower limit) is
  transient: `transient?/1` recognises `EMFILE`/`ENFILE` in file and native
  errors, and `retry/2` backs off and repeats an operation that failed so.
  """
  require Logger

  @key {__MODULE__, :budget}
  @target 1_048_576
  @reserve 64
  @min_cap 8
  @max_cap 1024
  @budget_wait 60_000

  @doc """
  Raise the open-files limit and size the budget from it; logs the limits.
  Returns `%{soft: n, hard: n, cap: n}`.
  """
  def init! do
    # Reporting an error must not need code loaded from disk when descriptors
    # run out: a release loads everything at boot, `mix run` lazily, so load the
    # runtime's own modules now (about 500, a fraction of a second).
    Code.ensure_all_loaded(
      for app <- [:kernel, :stdlib, :elixir, :logger],
          {:ok, modules} <- [:application.get_key(app, :modules)],
          module <- modules,
          do: module
    )

    {soft, hard} =
      case Valimc.Native.set_open_files_limit(@target) do
        {:ok, limits} -> limits
        {:error, _} -> {256, 256}
      end

    cap =
      Valimc.config(:open_files_budget) ||
        (soft - @reserve) |> div(2) |> max(@min_cap) |> min(@max_cap)

    set_cap(cap)
    Logger.info("Open files: limit #{soft} (hard #{hard}); logs hold at most #{cap}")
    %{soft: soft, hard: hard, cap: cap}
  end

  @doc "Set the cap (tests use a tiny one); descriptors in use are kept."
  def set_cap(cap) when is_integer(cap) and cap > 0 do
    case :persistent_term.get(@key, nil) do
      nil ->
        counter = :atomics.new(2, signed: true)
        :atomics.put(counter, 1, cap)
        :persistent_term.put(@key, counter)

      counter ->
        :atomics.put(counter, 1, cap)
    end

    :ok
  end

  @doc "The cap, or nil before `init!/0`."
  def cap do
    case :persistent_term.get(@key, nil) do
      nil -> nil
      counter -> :atomics.get(counter, 1)
    end
  end

  @doc "Descriptors taken from the budget now."
  def in_use do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      counter -> :atomics.get(counter, 2)
    end
  end

  @doc """
  Run `fun` holding `count` descriptors of the budget (waiting while it is
  full, up to a minute), then give them back. Without a budget (tools that do
  not start the server) `fun` just runs. `{:error, {:unwritten, :file_budget}}`
  if the budget stays full.
  """
  def with_files(count \\ 1, fun) do
    case :persistent_term.get(@key, nil) do
      nil ->
        fun.()

      counter ->
        if acquire(counter, count, System.monotonic_time(:millisecond) + @budget_wait, 1) do
          try do
            fun.()
          after
            :atomics.sub(counter, 2, count)
          end
        else
          {:error, {:unwritten, :file_budget}}
        end
    end
  end

  defp acquire(counter, count, deadline, delay) do
    if :atomics.add_get(counter, 2, count) <= max(:atomics.get(counter, 1), count) do
      true
    else
      :atomics.sub(counter, 2, count)

      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(delay)
        acquire(counter, count, deadline, min(delay * 2, 50))
      end
    end
  end

  @doc """
  Whether `reason` is the process or system running out of file descriptors:
  `:emfile`/`:enfile`, an OS error 23 or 24 in a native error, or a file
  error's message saying so, also nested in error tuples.
  """
  def transient?(reason) when reason in [:emfile, :enfile], do: true

  def transient?(reason) when is_binary(reason) do
    text = String.downcase(reason)

    String.contains?(text, "too many open files") or String.contains?(text, "os error 24") or
      String.contains?(text, "os error 23")
  end

  def transient?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&transient?/1)

  def transient?(_), do: false

  @doc """
  Run `fun` until it returns something other than a transient `{:error, _}`,
  backing off from 10 ms to 500 ms between tries, for at most `ms`
  milliseconds; then return its last result.
  """
  def retry(fun, ms \\ 5_000), do: retry(fun, System.monotonic_time(:millisecond) + ms, 10)

  defp retry(fun, deadline, delay) do
    case fun.() do
      {:error, reason} = error ->
        if transient?(reason) and System.monotonic_time(:millisecond) < deadline do
          if :ets.whereis(Valimc.Metrics) != :undefined, do: Valimc.Metrics.add(:file_retries)
          Process.sleep(delay)
          retry(fun, deadline, min(delay * 2, 500))
        else
          error
        end

      other ->
        other
    end
  end
end
