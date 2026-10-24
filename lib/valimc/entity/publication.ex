defmodule Valimc.Entity.Publication do
  @moduledoc """
  One published entity table per region for every entity kind (VMC-067,
  VMC-077h).

  Observer rows are `{{:entities, chunk}, {epoch, revision}, %{entity_id =>
  view}}`: the owner rewrites only the rows whose views changed, each with a
  fresh revision, and every view of a rewritten row carries the tick its
  tracker last ran (`tick`). Observers read the small stamp first and copy a
  chunk's views only when it changed.

  Each tick's frame, `%{entity_id => packets}` encoded once by the owner's
  trackers, goes into a ring of the last #{64} ticks
  (`{{:frame, slot}, tick, frame}`), and `{:frame_tick, tick}` names the newest.
  An observer forwards, for each entity it tracks, the packets of the frames
  after the view it spawned from; one that fell behind the ring resyncs.

  Compact `{:colliders, chunk}` rows hold only solid entity boxes and their
  handoff generations. Their stamps change with the boxes, so stationary
  player physics can invalidate a cached fit when a shulker's lid animates.

  The table also keeps the owner's full views (`{:entity_source, :items}`, what
  cross-region merge discovery reads) and a chunk index of row hashes
  (`:entity_index`).
  """

  @ring 64

  def ring, do: @ring

  @doc """
  Publish the observed `views` as of tracking tick `tick`, rewriting only
  changed chunk rows, then `frame`; `source` is the owner's full views.
  """
  def publish(table, epoch, tick, views, frame \\ %{}, source \\ nil) do
    :ets.insert(table, {{:entity_source, :items}, source || views})

    by_chunk =
      for {id, view} <- views, reduce: %{} do
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
            :ets.delete(table, {:colliders, chunk})
            {Map.delete(index, chunk), revision}

          {:ok, chunk_views} ->
            hash = :erlang.phash2(chunk_views)

            if index[chunk] == hash do
              {index, revision}
            else
              stamped =
                Map.new(chunk_views, fn {id, view} -> {id, Map.put(view, :tick, tick)} end)

              publish_colliders(table, chunk, {epoch, revision + 1}, chunk_views)
              :ets.insert(table, {{:entities, chunk}, {epoch, revision + 1}, stamped})
              {Map.put(index, chunk, hash), revision + 1}
            end
        end
      end)

    :ets.insert(table, {:entity_index, index, revision})

    # Rows first: an observer that reads the new frame tick also reads its rows.
    if frame != %{} do
      :ets.insert(table, {{:frame, rem(tick, @ring)}, tick, frame})
      :ets.insert(table, {:frame_tick, tick})
    end

    :ok
  end

  # Physics reads only solid boxes, without copying item or mob metadata.
  defp publish_colliders(table, chunk, stamp, views) do
    colliders =
      for {id, %{collider: box, ownership_generation: hops}} <- views,
          box != nil,
          into: %{},
          do: {id, {hops, box}}

    key = {:colliders, chunk}

    case :ets.lookup(table, key) do
      [{_, _, ^colliders}] -> :ok
      [] when colliders == %{} -> :ok
      _ when colliders == %{} -> :ets.delete(table, key)
      _ -> :ets.insert(table, {key, stamp, colliders})
    end
  end

  @doc "Solid collider observations in one chunk, with their publication stamp."
  def colliders(table, chunk) do
    case :ets.lookup(table, {:colliders, chunk}) do
      [{_, stamp, boxes}] -> {stamp, boxes}
      [] -> {nil, %{}}
    end
  rescue
    ArgumentError -> {nil, %{}}
  end

  @doc "The solid-collider stamp, without copying the boxes."
  def collider_stamp(table, chunk) do
    :ets.lookup_element(table, {:colliders, chunk}, 2)
  rescue
    ArgumentError -> nil
  end

  @doc """
  The frames of `table` after tick `last`: `{:ok, newest, [{tick, frame}]}`,
  or `{:gap, newest}` when the ring no longer holds them all. `last` nil (a
  region the observer starts reading) or past the newest (an owner that came
  back) reads none.
  """
  def frames(table, last) do
    newest =
      case :ets.lookup(table, :frame_tick) do
        [{:frame_tick, tick}] -> tick
        [] -> 0
      end

    cond do
      last == nil or last >= newest ->
        {:ok, newest, []}

      newest - last > @ring ->
        {:gap, newest}

      true ->
        frames =
          for tick <- (last + 1)..newest,
              [{_, ^tick, frame}] <- [:ets.lookup(table, {:frame, rem(tick, @ring)})],
              do: {tick, frame}

        {:ok, newest, frames}
    end
  end

  @doc "The last published views."
  def source(table, :items) do
    case :ets.lookup(table, {:entity_source, :items}) do
      [{_, views}] -> views
      [] -> %{}
    end
  end
end
