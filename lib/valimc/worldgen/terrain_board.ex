defmodule Valimc.Worldgen.TerrainBoard do
  @moduledoc """
  Which proto owners' terrain is most urgent (VMC-025d4). Each owner with
  queued terrain publishes the earliest `since` in its queue (when the
  transaction that asked for it first tried to finalize); an owner starts
  terrain jobs only while its own entry is among the most urgent, as many as
  `Valimc.Worldgen.Pool` holds. So the areas of transactions complete in
  the order they started, and decorate while later terrain is generated,
  instead of all at once at the end.

  Advisory only: the worker pool still bounds the jobs, and an entry of an
  owner that died is skipped and removed by the next reader. The application
  owns the table.
  """

  @doc "Create the table at application start (`Valimc.Application`)."
  def init! do
    :ets.new(__MODULE__, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok
  end

  @doc "Replace the caller's entry `old` (nil: none) with `new` (nil: none)."
  def put(old, old), do: :ok

  def put(old, new) do
    if old, do: :ets.delete(__MODULE__, {old, self()})
    if new, do: :ets.insert(__MODULE__, {{new, self()}})
    :ok
  end

  @doc "Whether the caller's entry `since` is among the `n` most urgent live ones."
  def urgent?(since, n), do: urgent?(:ets.first(__MODULE__), {since, self()}, n)

  defp urgent?(:"$end_of_table", _mine, _n), do: true
  defp urgent?(_entry, _mine, 0), do: false
  defp urgent?(mine, mine, _n), do: true

  defp urgent?({_, pid} = entry, mine, n) do
    next = :ets.next(__MODULE__, entry)

    if Process.alive?(pid) do
      urgent?(next, mine, n - 1)
    else
      :ets.delete(__MODULE__, entry)
      urgent?(next, mine, n)
    end
  end
end
