defmodule Valimc.Entity.Tracking do
  @moduledoc """
  An owner's replication state for its entities (VMC-077h): one tracker per
  entity (`Valimc.Entity.Tracker`), the spawn packet at each tracker's
  base, and the views of entities leaving in the outgoing handoff, kept until it
  clears so observers do not lose them on the way.

  It lives beside the entity store, never in it: planning workers copy the
  store, and a tracker must never go back to what clients already passed.
  Each tick's changes form one frame, `%{entity_id => packets}`, encoded once
  for every observer; `tick` is the last tick tracked, which every published
  row carries.
  """
  alias Valimc.Entity.{Tracker, View}

  defstruct trackers: %{}, spawns: %{}, departing: %{}, last: %{}, tick: 0

  @doc "One tick at `tick` over the store's `views`: `{tracking, frame}`."
  def step(tracking, views, outgoing, tick) do
    tracking = sync(tracking, views, outgoing)

    {trackers, spawns, frame} =
      Enum.reduce(views, {tracking.trackers, tracking.spawns, %{}}, fn {id, view}, acc ->
        {trackers, spawns, frame} = acc
        tracker = trackers[id]
        {next, packets} = tick(tracker, view)

        spawns =
          if next.base != tracker.base or next.movement != tracker.movement or
               next.rotation != tracker.rotation or next.head != tracker.head,
             do: Map.put(spawns, id, View.spawn(view, next.base, next.movement)),
             else: spawns

        frame = if packets == [], do: frame, else: Map.put(frame, id, packets)
        {Map.put(trackers, id, next), spawns, frame}
      end)

    {%{tracking | trackers: trackers, spawns: spawns, tick: tick}, frame}
  end

  defp tick(tracker, %{kind: kind} = view) when kind in [:mob, :object] do
    {next, packets} = Tracker.tick_body(tracker, view)
    {%{next | previous: view.velocity}, packets}
  end

  defp tick(tracker, view) do
    sync = sharp?(view, tracker)
    metadata = if view.metadata_revision != tracker.metadata, do: view.metadata
    {next, packets} = Tracker.tick(tracker, entity(view), sync, metadata)
    {%{next | previous: view.velocity, metadata: view.metadata_revision}, packets}
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
          tracker =
            case view do
              %{kind: kind} when kind in [:mob, :object] ->
                Tracker.new_body(view)

              _ ->
                %{
                  Tracker.new(view.at, view.velocity, view.on_ground)
                  | previous: view.velocity,
                    metadata: view.metadata_revision
                }
            end

          {Map.put(trackers, id, tracker),
           Map.put(spawns, id, View.spawn(view, view.at, view.velocity))}
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
      # A body: what selectors and observers read (its type and range, rotation, life).
      %{kind: kind} when kind in [:mob, :object] -> Map.merge(common, body_fields(view))
      _ -> common
    end
  end

  defp body_fields(view) do
    view
    |> Map.take([:type, :yaw, :pitch, :alive])
    |> Map.put(:box, Valimc.Entity.Body.box(view.body, view.at))
    |> Map.put(:range, Valimc.Data.EntityTypes.tracking_range(view.type))
    |> takeable(view)
    |> multipart(view)
  end

  # Keep the bounded part boxes in the observation, rather than copying the
  # dragon's phase paths and flight history to every nearby player.
  defp multipart(fields, %{type: "minecraft:ender_dragon", body: body}),
    do: Map.put(fields, :dragon_parts, body |> Valimc.Entity.Dragon.boxes() |> List.to_tuple())

  defp multipart(fields, _view), do: fields

  # A stuck arrow a player may take (`AbstractArrow.playerTouch`): in the
  # ground, its shake over, its pickup rule not disallowed. The owner checks
  # again when one is taken.
  defp takeable(fields, %{type: "minecraft:arrow", body: %{data: data}}) do
    Map.put(
      fields,
      :takeable,
      data.in_ground and data.shake <= 0 and data.pickup != :disallowed
    )
  end

  defp takeable(fields, _view), do: fields

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
