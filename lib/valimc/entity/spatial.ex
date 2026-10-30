defmodule Valimc.Entity.Spatial do
  @moduledoc """
  Owner-local chunk membership and exact solid boxes; queries fetch live
  store entries.

  Resting items (VMC-081l): `awake` holds, per chunk, the items that are
  not resting. A view change of an item wakes it, whatever changed, and only
  `rest/5` takes one out, so a store path that forgets resting can only
  leave an item awake. `resting` holds each resting item's chunk, the
  chunk clock at which its age reaches 6000 (`due`, nil for an unlimited
  age) and the chunks its tick reads (`deps`); `due` indexes those clocks
  per chunk and `deps` the resting items per chunk they read, with the
  chunk's publication as it was when they last rested on it, and `border`
  the world border they rest under.

  `items` counts the changes that can change which items merge: an item
  added or gone, moved, or its stack or merge eligibility changed (not its
  velocity or counters alone).
  """
  alias Valimc.Data.Box

  defstruct chunks: %{},
            solids: %{},
            types: %{},
            awake: %{},
            items: 0,
            resting: %{},
            due: %{},
            deps: %{},
            border: nil

  def put(index, id, old, view) do
    before = if old, do: {old.chunk, old.kind}
    after_key = if view, do: {view.chunk, view.kind}

    chunks =
      if before == after_key do
        index.chunks
      else
        index.chunks |> delete(before, id) |> insert(after_key, id)
      end

    index = unrest(index, id)

    awake =
      index.awake
      |> then(
        &if(old != nil and old.kind == :item, do: delete_present(&1, old.chunk, id), else: &1)
      )
      |> then(&if(view != nil and view.kind == :item, do: insert(&1, view.chunk, id), else: &1))

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

    items = if merge_change?(old, view), do: index.items + 1, else: index.items
    %{index | chunks: chunks, solids: solids, types: types, awake: awake, items: items}
  end

  defp merge_change?(%{kind: :item} = old, %{kind: :item} = view),
    do:
      old.at != view.at or old.count != view.count or old.merge_key != view.merge_key or
        old.merge_open != view.merge_open

  defp merge_change?(%{kind: :item}, _view), do: true
  defp merge_change?(_old, %{kind: :item}), do: true
  defp merge_change?(_old, _view), do: false

  @doc "How many items the index holds."
  def item_count(index) do
    Enum.reduce(index.chunks, 0, fn
      {{_, :item}, ids}, n -> n + MapSet.size(ids)
      _, n -> n
    end)
  end

  @doc """
  Item `id` in `chunk` rests: it leaves the chunk's awake items until its
  chunk clock reaches `due` (nil: never) or a chunk of `deps` (`[{chunk,
  publication}]`, the publications its tick read) is published again.
  """
  def rest(index, id, chunk, due, deps) do
    index = unrest(index, id)

    due_index =
      if due == nil,
        do: index.due,
        else:
          Map.update(
            index.due,
            chunk,
            :gb_sets.singleton({due, id}),
            &:gb_sets.add({due, id}, &1)
          )

    deps_index =
      Enum.reduce(deps, index.deps, fn {dep, publication}, acc ->
        Map.update(acc, dep, {publication, MapSet.new([id])}, fn {seen, ids} ->
          {seen, MapSet.put(ids, id)}
        end)
      end)

    %{
      index
      | awake: delete_present(index.awake, chunk, id),
        resting: Map.put(index.resting, id, {chunk, due, Enum.map(deps, &elem(&1, 0))}),
        due: due_index,
        deps: deps_index
    }
  end

  @doc "Item `id` is awake again (it is in the index)."
  def wake(index, id) do
    case index.resting do
      %{^id => {chunk, _, _}} -> %{unrest(index, id) | awake: insert(index.awake, chunk, id)}
      _ -> index
    end
  end

  @doc "Whether item `id` rests."
  def resting?(index, id), do: is_map_key(index.resting, id)

  @doc "The awake items in `chunks`, ids only."
  def awake(index, chunks),
    do: for(chunk <- chunks, id <- Map.get(index.awake, chunk, MapSet.new()), do: id)

  @doc "Whether `id` is an awake item of `chunk`."
  def awake?(index, chunk, id) do
    case index.awake do
      %{^chunk => ids} -> MapSet.member?(ids, id)
      _ -> false
    end
  end

  @doc """
  The resting items of `chunk` whose `due` clock is at most `clock`, in
  due order; they stay resting.
  """
  def due(index, chunk, clock) do
    case index.due do
      %{^chunk => set} -> take_due(:gb_sets.iterator(set), clock, [])
      _ -> []
    end
  end

  defp take_due(iterator, clock, acc) do
    case :gb_sets.next(iterator) do
      {{due, id}, next} when due <= clock -> take_due(next, clock, [id | acc])
      _ -> Enum.reverse(acc)
    end
  end

  @doc """
  The resting items to wake: every one when `border` is not the border they
  rest under, else those that read a chunk whose publication (`publication`
  gives it by chunk) is not the one they rested on. The index forgets those
  chunks and takes `border`.
  """
  def stale(%{resting: resting, border: border} = index, border, _publication)
      when map_size(resting) == 0,
      do: {[], index}

  def stale(%{resting: resting} = index, border, _publication)
      when map_size(resting) == 0,
      do: {[], %{index | border: border}}

  def stale(%{border: border} = index, border, publication) do
    {ids, deps} =
      Enum.reduce(index.deps, {[], index.deps}, fn {chunk, {seen, ids}}, {acc, deps} ->
        if publication.(chunk) === seen,
          do: {acc, deps},
          else: {MapSet.to_list(ids) ++ acc, Map.delete(deps, chunk)}
      end)

    if ids == [],
      do: {[], index},
      else: {Enum.filter(Enum.uniq(ids), &is_map_key(index.resting, &1)), %{index | deps: deps}}
  end

  def stale(index, border, _publication),
    do: {Map.keys(index.resting), %{index | border: border}}

  # Item `id` rests no more: it leaves the due clocks and dependencies.
  defp unrest(index, id) do
    case index.resting do
      %{^id => {chunk, due, deps}} ->
        due_index =
          case {due, index.due} do
            {nil, due_index} ->
              due_index

            {due, %{^chunk => set}} ->
              set = :gb_sets.del_element({due, id}, set)

              if :gb_sets.is_empty(set),
                do: Map.delete(index.due, chunk),
                else: Map.put(index.due, chunk, set)

            {_, due_index} ->
              due_index
          end

        deps_index =
          Enum.reduce(deps, index.deps, fn dep, acc ->
            case acc do
              %{^dep => {seen, ids}} ->
                ids = MapSet.delete(ids, id)

                if MapSet.size(ids) == 0,
                  do: Map.delete(acc, dep),
                  else: Map.put(acc, dep, {seen, ids})

              _ ->
                acc
            end
          end)

        %{index | resting: Map.delete(index.resting, id), due: due_index, deps: deps_index}

      _ ->
        index
    end
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

  defp delete_present(chunks, key, id) do
    case chunks do
      %{^key => _} -> delete(chunks, key, id)
      _ -> chunks
    end
  end
end
