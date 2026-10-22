defmodule Valimc.World.EntityTracking do
  @moduledoc """
  An owner's replication state for its entities (VMC-077h): one tracker per
  entity (`Valimc.World.EntityTracker`), the spawn packet at each tracker's
  base, and the views of entities leaving in the outgoing handoff, kept until it
  clears so observers do not lose them on the way.

  It lives beside the entity store, never in it: planning workers copy the
  store, and a tracker must never go back to what clients already passed.
  Each tick's changes form one frame, `%{entity_id => packets}`, encoded once
  for every observer; `tick` is the last tick tracked, which every published
  row carries.
  """
  alias Valimc.World.{EntityTracker, EntityView}

  defstruct trackers: %{}, spawns: %{}, departing: %{}, last: %{}, tick: 0

  @doc "One tick at `tick` over the store's `views`: `{tracking, frame}`."
  def step(tracking, views, outgoing, tick) do
    tracking = sync(tracking, views, outgoing)

    {trackers, spawns, frame} =
      Enum.reduce(views, {tracking.trackers, tracking.spawns, %{}}, fn {id, view}, acc ->
        {trackers, spawns, frame} = acc
        tracker = trackers[id]
        sync = sharp?(view, tracker)
        metadata = if view.metadata_revision != tracker.metadata, do: view.metadata
        {next, packets} = EntityTracker.tick(tracker, entity(view), sync, metadata)
        next = %{next | previous: view.velocity, metadata: view.metadata_revision}

        spawns =
          if next.base != tracker.base or next.movement != tracker.movement,
            do: Map.put(spawns, id, EntityView.spawn(view, next.base, next.movement)),
            else: spawns

        frame = if packets == [], do: frame, else: Map.put(frame, id, packets)
        {Map.put(trackers, id, next), spawns, frame}
      end)

    {%{tracking | trackers: trackers, spawns: spawns, tick: tick}, frame}
  end

  @doc """
  New entities get a tracker and gone ones lose it, except those leaving in
  the `outgoing` handoff: their last view stays published, frozen, until it
  clears, and an item a rejected merge returns keeps its tracker.
  """
  def sync(tracking, views, outgoing) do
    leaving =
      case outgoing do
        %{records: records} -> MapSet.new(records, &Map.get(&1, :entity_id))
        nil -> MapSet.new()
      end

    gone = for {id, _} <- tracking.trackers, not Map.has_key?(views, id), do: id

    {trackers, spawns, departing} =
      Enum.reduce(gone, {tracking.trackers, tracking.spawns, tracking.departing}, fn id, acc ->
        {trackers, spawns, departing} = acc

        cond do
          MapSet.member?(leaving, id) and Map.has_key?(tracking.last, id) ->
            {trackers, spawns, Map.put(departing, id, tracking.last[id])}

          MapSet.member?(leaving, id) and Map.has_key?(departing, id) ->
            acc

          true ->
            {Map.delete(trackers, id), Map.delete(spawns, id), Map.delete(departing, id)}
        end
      end)

    {trackers, spawns} =
      Enum.reduce(views, {trackers, spawns}, fn {id, view}, {trackers, spawns} ->
        if Map.has_key?(trackers, id) do
          {trackers, spawns}
        else
          tracker = %{
            EntityTracker.new(view.at, view.velocity, view.on_ground)
            | previous: view.velocity,
              metadata: view.metadata_revision
          }

          {Map.put(trackers, id, tracker),
           Map.put(spawns, id, EntityView.spawn(view, view.at, view.velocity))}
        end
      end)

    departing = Map.drop(departing, Map.keys(views))
    %{tracking | trackers: trackers, spawns: spawns, departing: departing, last: views}
  end

  @doc """
  What observers read: the store's views and the departing ones, as only the
  fields connections use, with their spawn, the base it is at and the
  tracker's incarnation (`tracker`). An item's
  `pickup_delay` is 0 once it can be picked up, else 1, so a delay counting
  down does not rewrite its row every tick.
  """
  def published(tracking, views) do
    tracking.departing
    |> Map.merge(views)
    |> Map.new(fn {id, view} ->
      {id, observed(view, tracking.spawns[id], tracking.trackers[id])}
    end)
  end

  defp observed(view, spawn, tracker) do
    common =
      Map.take(view, [
        :kind,
        :entity_id,
        :uuid,
        :epoch,
        :ownership_generation,
        :chunk,
        :at,
        :velocity,
        :on_ground,
        :metadata
      ])

    common = Map.merge(common, %{spawn: spawn, base: tracker.base, tracker: tracker.incarnation})

    case view do
      %{kind: :item, pickup_delay: delay} -> Map.put(common, :pickup_delay, min(delay, 1))
      %{kind: :orb} -> Map.merge(common, Map.take(view, [:value, :consumed]))
      _ -> common
    end
  end

  # Vanilla's `needsSync` for an item: its motion changed sharply this tick.
  defp sharp?(%{kind: :item, velocity: {x, y, z}}, %{previous: {px, py, pz}}),
    do: (x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz) > 0.01

  defp sharp?(_view, _tracker), do: false

  defp entity(view) do
    {x, y, z} = view.at

    %{
      entity_id: view.entity_id,
      x: x,
      y: y,
      z: z,
      velocity: view.velocity,
      on_ground: view.on_ground
    }
  end
end
