defmodule Valimc.Net.Profiler.Limits do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def admit(pid), do: GenServer.call(__MODULE__, {:admit, pid})
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call({:admit, pid}, _, state) do
    cond do
      Map.has_key?(state, pid) -> {:reply, :ok, state}
      map_size(state) >= 16 -> {:reply, :full, state}
      true -> {:reply, :ok, Map.put(state, pid, Process.monitor(pid))}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    {:noreply, if(state[pid] == ref, do: Map.delete(state, pid), else: state)}
  end
end
