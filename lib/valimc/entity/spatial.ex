defmodule Valimc.Entity.Spatial do
  @moduledoc "Owner-local chunk membership and exact solid boxes; queries fetch live store entries."
  alias Valimc.Data.Box

  defstruct chunks: %{}, solids: %{}, types: %{}

  def put(index, id, old, view) do
    before = if old, do: {old.chunk, old.kind}
    after_key = if view, do: {view.chunk, view.kind}

    chunks =
      if before == after_key do
        index.chunks
      else
        index.chunks |> delete(before, id) |> insert(after_key, id)
      end

    solids =
      case view do
        %{kind: :mob, body: %Valimc.Entity.NativeBody{} = row, at: at} ->
          case Valimc.Entity.NativeBody.collider(row, at) do
            nil -> Map.delete(index.solids, id)
            box -> Map.put(index.solids, id, box)
          end

        _ ->
          Map.delete(index.solids, id)
      end

    types =
      case {type(old), type(view)} do
        {same, same} -> index.types
        {before, after_type} -> index.types |> count(before, -1) |> count(after_type, 1)
      end

    %{index | chunks: chunks, solids: solids, types: types}
  end

  defp type(%{body: %{type: type}}), do: type
  defp type(_view), do: nil
  defp count(types, nil, _delta), do: types

  defp count(types, type, delta) do
    case Map.get(types, type, 0) + delta do
      0 -> Map.delete(types, type)
      n -> Map.put(types, type, n)
    end
  end

  def has_type?(index, type), do: Map.has_key?(index.types, type)

  defp insert(chunks, nil, _id), do: chunks
  defp insert(chunks, key, id), do: Map.update(chunks, key, MapSet.new([id]), &MapSet.put(&1, id))
  defp delete(chunks, nil, _id), do: chunks

  defp delete(chunks, key, id) do
    case MapSet.delete(Map.fetch!(chunks, key), id) do
      set when map_size(set.map) == 0 -> Map.delete(chunks, key)
      set -> Map.put(chunks, key, set)
    end
  end

  def in_chunks(index, entries, chunks, kind) do
    for chunk <- chunks,
        id <- Map.get(index.chunks, {chunk, kind}, MapSet.new()),
        do: {id, Map.fetch!(entries, id)}
  end

  def count_in_chunks(index, chunks, kind) do
    Enum.reduce(chunks, 0, fn chunk, n ->
      case index.chunks do
        %{{^chunk, ^kind} => ids} -> n + MapSet.size(ids)
        _ -> n
      end
    end)
  end

  def colliders(index, entries, area) do
    for {id, box} <- index.solids,
        Box.intersects?(area, box),
        do: {id, Map.fetch!(entries, id)}
  end
end
