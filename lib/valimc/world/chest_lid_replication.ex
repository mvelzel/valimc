defmodule Valimc.World.ChestLidReplication do
  @moduledoc "Connection-local visible lids, with one monitor per observed owner incarnation."
  defstruct positions: %{}, owners: %{}
  @max_positions 4096
  @max_owners 64

  def observe(state, owner, position, false), do: forget(state, position, owner)

  def observe(state, {pid, epoch} = owner, position, true)
      when is_pid(pid) and is_reference(epoch) do
    cond do
      state.positions[position] == owner ->
        state

      map_size(state.positions) >= @max_positions or
          (not Map.has_key?(state.owners, owner) and map_size(state.owners) >= @max_owners) ->
        state

      true ->
        state = forget(state, position, state.positions[position])
        record = Map.get_lazy(state.owners, owner, fn -> {Process.monitor(pid), MapSet.new()} end)
        {monitor, positions} = record

        %{
          state
          | positions: Map.put(state.positions, position, owner),
            owners: Map.put(state.owners, owner, {monitor, MapSet.put(positions, position)})
        }
    end
  end

  def retain(state, chunks) do
    Enum.reduce(state.positions, state, fn {{x, _, z} = position, owner}, current ->
      if MapSet.member?(chunks, Valimc.World.chunk_key(x, z)),
        do: current,
        else: forget(current, position, owner)
    end)
  end

  def down(state, monitor, pid) do
    case Enum.find(state.owners, fn {{owner_pid, _}, {ref, _}} ->
           owner_pid == pid and monitor == ref
         end) do
      {owner, {_, positions}} ->
        {%{
           state
           | positions: Map.drop(state.positions, MapSet.to_list(positions)),
             owners: Map.delete(state.owners, owner)
         }, MapSet.to_list(positions)}

      nil ->
        {state, []}
    end
  end

  defp forget(state, position, owner) do
    case {state.positions[position], state.owners[owner]} do
      {^owner, {monitor, positions}} ->
        positions = MapSet.delete(positions, position)

        owners =
          if MapSet.size(positions) == 0 do
            Process.demonitor(monitor, [:flush])
            Map.delete(state.owners, owner)
          else
            Map.put(state.owners, owner, {monitor, positions})
          end

        %{state | positions: Map.delete(state.positions, position), owners: owners}

      _ ->
        state
    end
  end
end
