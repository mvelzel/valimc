defmodule Valimc.Entity.Publication do
  @moduledoc """
  One published entity table per region for every entity kind (VMC-067,
  VMC-077h).

  Observer rows are `{{:entities, chunk}, {epoch, revision}, %{entity_id =>
  view}}`: the owner rewrites only the rows whose views changed, each with a
  fresh revision, and every view of a rewritten row carries the tick its
  tracker last ran (`tick`). Observers read the small stamp first and copy a
  chunk's views only when it changed.

  Each tick's frame, the packets the owner's trackers encoded once as frame
  entries (`Valimc.Entity.Tracking`), goes into a ring of the last #{64}
  ticks (`{{:frame, slot}, tick, frame}`), and `{:frame_tick, tick}` names
  the newest.
  An observer forwards, for each entity it tracks, the packets of the frames
  after the view it spawned from; one that fell behind the ring resyncs.

  Compact `{:colliders, chunk}` rows hold only solid entity boxes and their
  handoff generations. Their stamps change with the boxes, so stationary
  player physics can invalidate a cached fit when a shulker's lid animates.

  The table also keeps the owner's full views, one row per entity rewritten
  when it changes (`{{:entity_source, id}, view}`: what cross-region merge
  discovery and selectors read), and an index of the chunks with rows
  (`:entity_index`).
  """

  @ring 64

  def ring, do: @ring

  @doc "An empty publication of incarnation `epoch`: no rows, revision 0."
  def init(table, epoch) do
    :ets.insert(table, [{:entity_index, %{}, 0}, {:entity_revision, {epoch, 0}}])
    :ok
  end

  @doc """
  Publish a tracking pass (`Valimc.Entity.Tracking.pass/6`) as of tick
  `tick`: its changed chunk rows (an empty one retires), the changed
  sources (one row per entity, `{{:entity_source, id}, view}`) and its frame
  (a binary of frame entries; an empty one is not written).
  """
  def publish(table, epoch, tick, %{rows: rows, sources: sources, frame: frame}) do
    Enum.each(sources, fn
      {id, nil} -> :ets.delete(table, {:entity_source, id})
      {id, view} -> :ets.insert(table, {{:entity_source, id}, view})
    end)

    if rows != %{} do
      [{:entity_index, index, revision}] = :ets.lookup(table, :entity_index)

      {index, revision} =
        Enum.reduce(rows, {index, revision}, fn
          {chunk, row}, {index, revision} when row == %{} ->
            :ets.delete(table, {:entities, chunk})
            :ets.delete(table, {:colliders, chunk})
            {Map.delete(index, chunk), revision + 1}

          {chunk, row}, {index, revision} ->
            stamp = {epoch, revision + 1}
            publish_colliders(table, chunk, stamp, row)
            :ets.insert(table, {{:entities, chunk}, stamp, row})
            {Map.put(index, chunk, revision + 1), revision + 1}
        end)

      :ets.insert(table, {:entity_index, index, revision})
      # Published after the rows: an unchanged section needs no chunk lookups.
      :ets.insert(table, {:entity_revision, {epoch, revision}})
    end

    if frame != <<>> do
      :ets.insert(table, {{:frame, rem(tick, @ring)}, tick, frame})
      :ets.insert(table, {:frame_tick, tick})
    end

    :ok
  end

  @doc "Section incarnation and publication revision; empty chunks need no rows."
  def revision(table), do: :ets.lookup_element(table, :entity_revision, 2, nil)

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

  @doc "The owner's views (its store's), by id."
  def source(table) do
    table
    |> :ets.match({{:entity_source, :"$1"}, :"$2"})
    |> Map.new(fn [id, view] -> {id, view} end)
  end

  def source(table, :items), do: source(table)
end
