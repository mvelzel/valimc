defmodule Valimc.Entity.Observer do
  @moduledoc """
  One observer's tracked entities (VMC-077h): it forwards the frames its
  regions' owners encoded once, for the entities it tracks, and encodes
  nothing on the hot path.

  - A newly visible entity spawns from its row: the spawn packet at its
    tracker's base and its metadata (a player's is all of its data and
    equipment, VMC-077i4), paced by a batch budget. Frames up to the
    row's tick are already in that spawn.
  - A tracked entity gets each later frame's packets, in tick order.
  - An entity seen under another owner or tracker (a handoff keeps its id; the reader
    keeps the newer owner's view while both publish it) or in a region whose
    frames the observer fell behind on resyncs: an absolute position, its
    motion and metadata, never a respawn.
  - An entity no longer visible is removed.
  """
  alias Valimc.Protocol.EntityPackets
  alias Valimc.Entity.View

  defstruct tracked: %{}, regions: %{}
  @max_visible 1024
  @max_spawns 64
  @max_bytes 262_144

  def new, do: %__MODULE__{}
  def max_visible, do: @max_visible

  @doc """
  Bring the observer toward `desired` views of any kind. `frames` reads a
  region's frames after a tick (`Valimc.Entity.Publication.frames/2`):
  `fn region, last -> {:ok, newest, frames} | {:gap, newest} end`.
  Returns `{state, packets}`.
  """
  def reconcile(state, desired, frames) when map_size(desired) <= @max_visible do
    {tracked, removed} =
      Enum.reduce(state.tracked, {state.tracked, []}, fn {id, _}, {tracked, removed} ->
        if is_map_key(desired, id),
          do: {tracked, removed},
          else: {Map.delete(tracked, id), [id | removed]}
      end)

    removal =
      if removed == [], do: [], else: [binary_packet(EntityPackets.remove(Enum.sort(removed)))]

    # An entity seen under another owner (its id survived a handoff) or with
    # a new tracker (handed back to its section).
    {tracked, resyncs} =
      Enum.reduce(tracked, {tracked, []}, fn {id, entry}, {tracked, packets} ->
        view = desired[id]

        if view.epoch == entry.epoch and view.tracker == entry.tracker,
          do: {tracked, packets},
          else: resync(tracked, packets, id, view)
      end)

    # A region read for the first time starts at its entities' oldest view.
    reads =
      tracked
      |> Enum.reduce(%{}, fn {_, entry}, acc ->
        Map.update(acc, entry.region, entry.since, &min(&1, entry.since))
      end)
      |> Map.new(fn {region, since} ->
        {region, frames.(region, Map.get(state.regions, region, since))}
      end)

    {tracked, updates} =
      Enum.reduce(reads, {tracked, resyncs}, fn
        {region, {:gap, _}}, {tracked, packets} ->
          for({id, %{region: ^region}} <- tracked, do: id)
          |> Enum.reduce({tracked, packets}, fn id, {tracked, packets} ->
            resync(tracked, packets, id, desired[id])
          end)

        {region, {:ok, _, ticks}}, acc ->
          for {tick, frame} <- ticks, {id, sent} <- frame, reduce: acc do
            {tracked, packets} ->
              case tracked do
                %{^id => %{region: ^region, since: since}} when tick > since ->
                  {tracked, Enum.reverse(sent, packets)}

                _ ->
                  {tracked, packets}
              end
          end
      end)

    {tracked, spawns, spawned} = spawn(tracked, desired)

    regions =
      spawned
      |> Enum.reject(fn {region, _} -> is_map_key(reads, region) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {region, ticks} -> {region, Enum.min(ticks)} end)
      |> Map.merge(Map.new(reads, fn {region, read} -> {region, elem(read, 1)} end))

    {%{state | tracked: tracked, regions: regions}, removal ++ Enum.reverse(updates) ++ spawns}
  end

  @doc "Forget the entity `id` (a peer that respawned): its row spawns it again."
  def untrack(state, id), do: %{state | tracked: Map.delete(state.tracked, id)}

  defp resync(tracked, packets, id, view) do
    entry = entry(view)
    {x, y, z} = view.base

    entity = %{
      entity_id: id,
      x: x,
      y: y,
      z: z,
      yaw: Map.get(view, :yaw, 0.0),
      pitch: Map.get(view, :pitch, 0.0),
      on_ground: view.on_ground
    }

    sync =
      [
        binary_packet(EntityPackets.position(entity)),
        binary_packet(EntityPackets.motion(id, view.velocity))
      ] ++ List.wrap(view.metadata)

    {Map.put(tracked, id, entry), Enum.reverse(sync, packets)}
  end

  # New entities in id order, within the batch budget; the rest wait a pass.
  # A region first read for spawned entities starts after the oldest spawn's
  # tick; the frames up to each spawn's own tick are skipped by `since`.
  defp spawn(tracked, desired) do
    desired
    |> Enum.reject(fn {id, _} -> is_map_key(tracked, id) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({tracked, [], [], 0}, fn {id, view},
                                                  {tracked, packets, spawned, bytes} ->
      bundle = [view.spawn | List.wrap(view.metadata)]
      cost = Enum.reduce(bundle, 0, &(View.packet_bytes(&1) + &2))

      if length(spawned) >= @max_spawns or bytes + cost > @max_bytes do
        {:halt, {tracked, packets, spawned, bytes}}
      else
        entry = entry(view)

        {:cont,
         {Map.put(tracked, id, entry), Enum.reverse(bundle, packets),
          [{entry.region, view.tick} | spawned], bytes + cost}}
      end
    end)
    |> then(fn {tracked, packets, spawned, _} ->
      {tracked, Enum.reverse(packets), spawned}
    end)
  end

  defp entry(view),
    do: %{epoch: view.epoch, tracker: view.tracker, since: view.tick, region: region(view)}

  defp region(view), do: Valimc.World.region_key(view.chunk)

  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
