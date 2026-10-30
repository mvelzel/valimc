defmodule Valimc.Entity.Observer do
  @moduledoc """
  One observer's tracked entities (VMC-077h, VMC-081i): it forwards the
  frames its regions' owners encoded once, for the entities it tracks, and
  encodes nothing on the hot path.

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

  Membership changes arrive as the ids they touch
  (`Valimc.Session.EntityMembership`): only those are examined, and the
  entities waiting for a spawn's budget (`waiting`); `:all` examines every
  desired and tracked one.
  """
  alias Valimc.Data.Grid
  alias Valimc.Protocol.EntityPackets
  alias Valimc.Entity.View

  defstruct tracked: %{}, regions: %{}, counts: %{}, waiting: MapSet.new()
  @max_visible 1024
  @max_spawns 64
  @max_bytes 262_144

  def new, do: %__MODULE__{}
  def max_visible, do: @max_visible

  @doc """
  Bring the observer toward `desired` views of any kind, examining the ids
  `touched` (or `:all`). `frames` reads a region's frames after a tick
  (`Valimc.Entity.Publication.frames/2`): `fn region, last -> {:ok, newest,
  frames} | {:gap, newest} end`. Returns `{state, packets}`.
  """
  def reconcile(state, desired, touched \\ :all, frames)

  def reconcile(state, desired, touched, frames) when map_size(desired) <= @max_visible do
    {state, removed, resyncs} = membership(state, desired, touched)

    removal =
      if removed == [], do: [], else: [binary_packet(EntityPackets.remove(Enum.sort(removed)))]

    {state, updates} = forward(state, desired, resyncs, frames)
    {state, spawns} = spawn(state, desired)
    {state, removal ++ Enum.reverse(updates) ++ spawns}
  end

  @doc "Forget the entity `id` (a peer that respawned): its row spawns it again."
  def untrack(state, id) do
    case state.tracked do
      %{^id => entry} ->
        %{
          drop(state, id, entry)
          | waiting: MapSet.put(state.waiting, id)
        }

      _ ->
        state
    end
  end

  # Removals and resyncs among the examined ids; the others desired and not
  # tracked wait for a spawn.
  defp membership(state, desired, :all) do
    {state, removed} =
      Enum.reduce(state.tracked, {state, []}, fn {id, entry}, {state, removed} ->
        if is_map_key(desired, id),
          do: {state, removed},
          else: {drop(state, id, entry), [id | removed]}
      end)

    {state, resyncs} =
      Enum.reduce(state.tracked, {state, []}, fn {id, entry}, acc ->
        resync_changed(acc, id, entry, desired[id])
      end)

    waiting =
      for {id, _} <- desired, not is_map_key(state.tracked, id), into: MapSet.new(), do: id

    {%{state | waiting: waiting}, removed, resyncs}
  end

  defp membership(state, desired, touched) do
    Enum.reduce(touched, {state, [], []}, fn id, {state, removed, resyncs} ->
      case {state.tracked, desired} do
        {%{^id => entry}, %{^id => view}} ->
          {state, resyncs} = resync_changed({state, resyncs}, id, entry, view)
          {state, removed, resyncs}

        {%{^id => entry}, _} ->
          {drop(state, id, entry), [id | removed], resyncs}

        {_, %{^id => _}} ->
          {%{state | waiting: MapSet.put(state.waiting, id)}, removed, resyncs}

        _ ->
          {%{state | waiting: MapSet.delete(state.waiting, id)}, removed, resyncs}
      end
    end)
  end

  # An entity seen under another owner (its id survived a handoff) or with
  # a new tracker (handed back to its section).
  defp resync_changed({state, packets}, id, entry, view) do
    if view.epoch == entry.epoch and view.tracker == entry.tracker,
      do: {state, packets},
      else: resync(state, packets, id, view)
  end

  defp drop(state, id, entry) do
    %{
      state
      | tracked: Map.delete(state.tracked, id),
        counts: uncount(state.counts, entry.region)
    }
  end

  defp uncount(counts, region) do
    case counts do
      %{^region => 1} -> Map.delete(counts, region)
      %{^region => n} -> Map.put(counts, region, n - 1)
      _ -> counts
    end
  end

  defp track(state, id, entry) do
    counts =
      case state.tracked do
        %{^id => old} -> uncount(state.counts, old.region)
        _ -> state.counts
      end

    %{
      state
      | tracked: Map.put(state.tracked, id, entry),
        counts: Map.update(counts, entry.region, 1, &(&1 + 1))
    }
  end

  # Each tracked region's frames; a region read for the first time starts
  # at its entities' oldest view, one the observer fell behind on resyncs.
  defp forward(state, desired, resyncs, frames) do
    reads =
      Map.new(state.counts, fn {region, _} ->
        last =
          case state.regions do
            %{^region => last} -> last
            _ -> oldest(state.tracked, region)
          end

        {region, frames.(region, last)}
      end)

    {state, packets} =
      Enum.reduce(reads, {state, resyncs}, fn
        {region, {:gap, _}}, {state, packets} ->
          for({id, %{region: ^region}} <- state.tracked, do: id)
          |> Enum.reduce({state, packets}, fn id, {state, packets} ->
            resync(state, packets, id, desired[id])
          end)

        {region, {:ok, _, ticks}}, {state, packets} ->
          packets =
            Enum.reduce(ticks, packets, fn {tick, frame}, packets ->
              forward(frame, tick, region, state.tracked, packets)
            end)

          {state, packets}
      end)

    regions = Map.new(reads, fn {region, read} -> {region, elem(read, 1)} end)
    {%{state | regions: regions}, packets}
  end

  defp oldest(tracked, region) do
    for({_, %{region: ^region, since: since}} <- tracked, do: since) |> Enum.min(fn -> nil end)
  end

  # A frame's entries (`Valimc.Entity.Tracking`) of the entities this
  # observer tracks from `region` since before `tick`, newest first.
  defp forward(
         <<id::32-signed, packet::16, size::32, payload::binary-size(size), rest::binary>>,
         tick,
         region,
         tracked,
         packets
       ) do
    case tracked do
      %{^id => %{region: ^region, since: since}} when tick > since ->
        forward(rest, tick, region, tracked, [{packet, payload} | packets])

      _ ->
        forward(rest, tick, region, tracked, packets)
    end
  end

  defp forward(<<>>, _tick, _region, _tracked, packets), do: packets

  defp resync(state, packets, id, view) do
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

    {track(state, id, entry), Enum.reverse(sync, packets)}
  end

  # New entities in id order, within the batch budget; the rest wait a pass.
  # A region first read for spawned entities starts after the oldest spawn's
  # tick; the frames up to each spawn's own tick are skipped by `since`.
  defp spawn(%{waiting: waiting} = state, _desired) when map_size(waiting) == 0,
    do: {state, []}

  defp spawn(state, desired) do
    state.waiting
    |> Enum.sort()
    |> Enum.reduce_while({state, [], 0, 0}, fn id, {state, packets, spawned, bytes} ->
      view = desired[id]

      cond do
        view == nil or is_map_key(state.tracked, id) ->
          {:cont, {%{state | waiting: MapSet.delete(state.waiting, id)}, packets, spawned, bytes}}

        true ->
          bundle = [view.spawn | List.wrap(view.metadata)]
          cost = Enum.reduce(bundle, 0, &(View.packet_bytes(&1) + &2))

          if spawned >= @max_spawns or bytes + cost > @max_bytes do
            {:halt, {state, packets, spawned, bytes}}
          else
            entry = entry(view)
            state = %{track(state, id, entry) | waiting: MapSet.delete(state.waiting, id)}

            regions =
              Map.update(state.regions, entry.region, view.tick, &min(&1, view.tick))

            {:cont,
             {%{state | regions: regions}, Enum.reverse(bundle, packets), spawned + 1,
              bytes + cost}}
          end
      end
    end)
    |> then(fn {state, packets, _, _} -> {state, Enum.reverse(packets)} end)
  end

  defp entry(view),
    do: %{epoch: view.epoch, tracker: view.tracker, since: view.tick, region: region(view)}

  defp region(view), do: Grid.region_key(view.chunk)

  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
