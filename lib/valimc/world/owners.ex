defmodule Valimc.World.Owners do
  @moduledoc """
  Finding or starting an owner process (VMC-077g): one helper for region
  owners (through the Directory), generation schedulers and log stripes.

  A registration can outlive its process for a moment (the registry drops it
  once it sees the exit), and a starting owner can find its predecessor still
  going away; both are waited out 1 ms at a time, a bounded number of times.
  """

  @doc """
  The live owner: `find.()` returns the registered pid or nil; `start.()`
  returns `{:ok, pid}`, `{:error, {:already_started, pid}}`, `:retry` (a
  predecessor is still going away) or another `{:error, reason}`, returned as
  is. After `attempts` waits, `{:error, restarting}`.
  """
  def ensure(find, start, restarting, attempts \\ 100)

  def ensure(_find, _start, restarting, 0), do: {:error, restarting}

  def ensure(find, start, restarting, attempts) do
    case find.() do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: wait(find, start, restarting, attempts)

      nil ->
        case start.() do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            if Process.alive?(pid), do: {:ok, pid}, else: wait(find, start, restarting, attempts)

          :retry ->
            wait(find, start, restarting, attempts)

          {:error, _} = error ->
            error
        end
    end
  end

  @doc "A `find` function for a unique `Registry` key."
  def registered(registry, key) do
    fn ->
      case Registry.lookup(registry, key) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end

  defp wait(find, start, restarting, attempts) do
    Process.sleep(1)
    ensure(find, start, restarting, attempts - 1)
  end
end
