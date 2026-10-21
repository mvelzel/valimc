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
  it).

  The budget is a public ETS table of slots, not a process: holding a
  descriptor is owning a row `{slot, pid}`, taken with `:ets.insert_new/2`, so
  every descriptor taken names its holder. A holder killed inside `with_files/2`
  (`Process.exit(pid, :kill)`, a brutal shutdown) never runs its `after`, and
  its rows stay; a caller that finds the budget full deletes the rows of dead
  holders, then backs off and tries again. Rows are deleted as whole objects,
  so a slot taken again since is never freed by mistake. The table belongs to
  the process that creates the budget, the application's start (`init!/0`).

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

  @doc """
  Set the cap (tests use a tiny one); descriptors in use are kept. Creates the
  budget, owned by the caller, if there is none (or its owner has stopped).
  """
  def set_cap(cap) when is_integer(cap) and cap > 0 do
    case :persistent_term.get(@key, nil) do
      {table, settings} ->
        if :ets.info(table, :size) == :undefined,
          do: create(cap),
          else: :atomics.put(settings, 1, cap)

      _ ->
        create(cap)
    end

    :ok
  end

  # Settings: [cap, the slot the next caller probes first].
  defp create(cap) do
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    settings = :atomics.new(2, signed: false)
    :atomics.put(settings, 1, cap)
    :persistent_term.put(@key, {table, settings})
  end

  @doc "The cap, or nil before `init!/0`."
  def cap do
    case :persistent_term.get(@key, nil) do
      nil -> nil
      {_, settings} -> :atomics.get(settings, 1)
    end
  end

  @doc "Descriptors taken from the budget now, dead holders' not yet reclaimed among them."
  def in_use do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      {table, _} -> :ets.info(table, :size)
    end
  end

  @doc """
  Run `fun` holding `count` descriptors of the budget (waiting while it is
  full, up to a minute), then give them back. Without a budget (tools that do
  not start the server) `fun` just runs. `{:error, {:unwritten, :file_budget}}`
  if the budget stays full. Descriptors of a caller killed meanwhile go back
  once the budget is next found full.
  """
  def with_files(count \\ 1, fun) do
    case :persistent_term.get(@key, nil) do
      nil ->
        fun.()

      {table, settings} ->
        deadline = System.monotonic_time(:millisecond) + @budget_wait

        case acquire(table, settings, count, deadline, 1) do
          {:ok, slots} ->
            try do
              fun.()
            after
              Enum.each(slots, &:ets.delete_object(table, {&1, self()}))
            end

          :full ->
            {:error, {:unwritten, :file_budget}}
        end
    end
  end

  # More than the cap at once fits only an otherwise empty budget.
  defp acquire(table, settings, count, deadline, delay) do
    slots = max(:atomics.get(settings, 1), count)

    with true <- :ets.info(table, :size) + count <= slots,
         {:ok, _} = taken <-
           take(table, slots, rem(:atomics.add_get(settings, 2, 1), slots), slots, count, []) do
      taken
    else
      _full ->
        cond do
          reclaim(table) > 0 ->
            acquire(table, settings, count, deadline, delay)

          System.monotonic_time(:millisecond) >= deadline ->
            :full

          true ->
            Process.sleep(delay)
            acquire(table, settings, count, deadline, min(delay * 2, 50))
        end
    end
  end

  # Probe slots from `at` round the ring of `slots`, inserting rows that name
  # this process, until `count` are taken; give them back if they are not.
  defp take(_table, _slots, _at, _left, 0, taken), do: {:ok, taken}

  defp take(table, _slots, _at, 0, _count, taken) do
    Enum.each(taken, &:ets.delete_object(table, {&1, self()}))
    :full
  end

  defp take(table, slots, at, left, count, taken) do
    slot = at + 1
    next = rem(slot, slots)

    if :ets.insert_new(table, {slot, self()}),
      do: take(table, slots, next, left - 1, count - 1, [slot | taken]),
      else: take(table, slots, next, left - 1, count, taken)
  end

  # Free the slots of holders that died holding them; how many were freed.
  defp reclaim(table) do
    table
    |> :ets.tab2list()
    |> Enum.count(fn {_slot, pid} = row ->
      not Process.alive?(pid) and :ets.delete_object(table, row)
    end)
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
