defmodule Valimc.World.EntityPublication do
  @moduledoc """
  One published entity view table per region for every entity kind (VMC-067).

  Observer rows are `{{:entities, chunk}, {epoch, revision}, %{entity_id => view}}`.
  The owner republishes its store's views (every kind, VMC-077h) only once they
  are durable. It keeps the last durable views (`{:entity_source, :items}`) and a
  chunk index of view hashes
  (`:entity_index`) in the same table, and rewrites only the chunk rows whose
  views changed, each with a fresh revision. Observers read the small stamp
  first and copy a chunk's views only when it changed.
  """

  @kinds [:items]

  @doc "Publish `kind`'s durable `views`, rewriting only changed chunk rows."
  def publish(table, epoch, kind, views) when kind in @kinds do
    :ets.insert(table, {{:entity_source, kind}, views})

    by_chunk =
      for kind <- @kinds, {id, view} <- source(table, kind), reduce: %{} do
        acc -> Map.update(acc, view.chunk, %{id => view}, &Map.put(&1, id, view))
      end

    {index, revision} =
      case :ets.lookup(table, :entity_index) do
        [{:entity_index, index, revision}] -> {index, revision}
        [] -> {%{}, 0}
      end

    chunks = Enum.uniq(Map.keys(index) ++ Map.keys(by_chunk))

    {index, revision} =
      Enum.reduce(chunks, {index, revision}, fn chunk, {index, revision} ->
        case Map.fetch(by_chunk, chunk) do
          :error ->
            :ets.delete(table, {:entities, chunk})
            {Map.delete(index, chunk), revision}

          {:ok, chunk_views} ->
            hash = :erlang.phash2(chunk_views)

            if index[chunk] == hash do
              {index, revision}
            else
              :ets.insert(table, {{:entities, chunk}, {epoch, revision + 1}, chunk_views})
              {Map.put(index, chunk, hash), revision + 1}
            end
        end
      end)

    :ets.insert(table, {:entity_index, index, revision})
    :ok
  end

  @doc "The last durable views of one kind."
  def source(table, kind) do
    case :ets.lookup(table, {:entity_source, kind}) do
      [{_, views}] -> views
      [] -> %{}
    end
  end
end
