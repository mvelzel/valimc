defmodule Valimc.Entity.Tracking do
  @moduledoc """
  An owner's replication state for its entities (VMC-077h, VMC-081i): one
  tracker per entity, the spawn packet at each tracker's base, what observers
  read of each entity (its row view), and the views of entities leaving in
  the outgoing handoff, kept until it clears so observers do not lose them on
  the way.

  It lives beside the entity store, never in it: planning workers copy the
  store, and a tracker must never go back to what clients already passed.

  A native mob's tracker lives on its section's slot (`valimc_core::tracker`,
  `Native.mob_section_track/5`); this module keeps its Elixir half (`natives`:
  the base observers were sent, the tracker's incarnation, the last entity
  event and data shown). Every other entity's is a `Valimc.Entity.Tracker`.

  Each pass works on what changed: the store's views are compared with the
  last pass's (an untouched store is the same term, so a static section
  costs nothing), only changed entities are projected again and only their
  chunks' rows are rewritten, and on a tick only the trackers of entities in
  simulated chunks (vanilla's entity-ticking chunks) and of entities whose
  view changed tick. Each tick's packets form one frame, a binary of entries
  `<<entity id::32, packet id::16, size::32, payload::binary-size(size)>>`
  encoded once for every observer; `tick` is the last tick tracked, which
  every rewritten row carries.
  """
  alias Valimc.Entity.{NativeBody, NativeMobs, Tracker, View}
  alias Valimc.Protocol.Packets

  defstruct trackers: %{},
            natives: %{},
            spawns: %{},
            departing: %{},
            last: %{},
            players: %{},
            published: %{},
            chunks: %{},
            pending: MapSet.new(),
            fresh: [],
            tick: 0

  @packets ~w(add_entity set_entity_motion entity_position_sync move_entity_pos
              move_entity_pos_rot move_entity_rot rotate_head)

  @doc "The packet ids a native tracker writes (`valimc_core::tracker::PacketIds`)."
  def packet_ids,
    do: @packets |> Enum.map(&elem(Packets.packet(&1, <<>>), 0)) |> List.to_tuple()

  @doc """
  One pass at `tick` over the store's `views` and the players standing in
  the section (`players`: `{views, frame}`), with the outgoing handoff
  `outgoing`. `opts`:

  - `simulated`: the chunks whose entities' trackers tick (a MapSet), or nil
    for a publication between ticks, where no tracker ticks;
  - `native` and `mask`: the section's native mobs (`NativeMobs`) and its
    simulated chunks as their mask (`NativeMobs.simulated_mask/2`, or `:all`).

  Returns `{tracking, publication}`: the chunk rows to rewrite (`%{chunk =>
  %{id => view}}`, empty for a row that goes), the store views whose source
  changed (`[{id, view | nil}]`) and the frame.
  """
  def pass(tracking, views, players, outgoing, tick, opts \\ []) do
    {player_views, player_frame} = players
    {changed, removed} = diff(tracking.last, views)
    {tracking, refresh} = sync(tracking, views, changed, removed, outgoing)

    {tracking, frame, respawned} =
      case Keyword.get(opts, :simulated) do
        nil ->
          {tracking, [], []}

        simulated ->
          native = Keyword.get(opts, :native)
          mask = Keyword.get(opts, :mask, 0)
          tick_trackers(%{tracking | tick: tick}, views, simulated, native, mask)
      end

    {tracking, chunks} = refresh(tracking, views, refresh ++ respawned)
    {tracking, chunks} = refresh_players(tracking, player_views, chunks)
    frame = [frame | encode_frame(player_frame)]

    # A body's entity events are its tracker's, not its readers'.
    sources =
      Enum.map(changed, &{&1, Map.delete(views[&1], :events)}) ++ Enum.map(removed, &{&1, nil})

    publication = %{
      rows: rows(tracking, chunks, tick),
      sources: sources,
      frame: IO.iodata_to_binary(frame)
    }

    {%{tracking | last: views}, publication}
  end

  @doc """
  Whether a tick's pass has nothing to do: the store's views and the
  players' rows are the terms the last pass saw, nothing waits, and no
  tracker stands in a simulated chunk.
  """
  def idle?(tracking, views, {player_views, player_frame}, simulated) do
    views === tracking.last and player_views === tracking.players and player_frame == %{} and
      tracking.departing == %{} and tracking.fresh == [] and MapSet.size(tracking.pending) == 0 and
      (MapSet.size(simulated) == 0 or (tracking.trackers == %{} and tracking.natives == %{}))
  end

  @doc """
  An idle tracking (`idle?/4`) over `views` and `player_views`, which equal
  what it last saw: `{:rebased, tracking}` keeping these terms where they
  are other terms than its own (a state copied in by message), so the
  next `idle?/4` finds them identical without comparing them, else
  `:same`.
  """
  def same(%__MODULE__{} = tracking, views, player_views) do
    if :erts_debug.same(tracking.last, views) and :erts_debug.same(tracking.players, player_views),
      do: :same,
      else: {:rebased, %{tracking | last: views, players: player_views}}
  end

  # The ids whose view is new or another term, and the ids gone.
  defp diff(last, views) when last === views, do: {[], []}

  defp diff(last, views) do
    {changed, added} =
      Enum.reduce(views, {[], 0}, fn {id, view}, {changed, added} = acc ->
        case last do
          %{^id => ^view} -> acc
          %{^id => _} -> {[id | changed], added}
          _ -> {[id | changed], added + 1}
        end
      end)

    removed =
      if map_size(last) + added == map_size(views),
        do: [],
        else: for({id, _} <- last, not is_map_key(views, id), do: id)

    {changed, removed}
  end

  # New entities get a tracker and gone ones lose it, except those leaving in
  # the outgoing handoff: their last view stays published, frozen, until it
  # clears, and an item a rejected merge returns keeps its tracker.
  defp sync(tracking, views, changed, removed, outgoing) do
    leaving =
      case outgoing do
        %{records: records} -> MapSet.new(records, &Map.get(&1, :entity_id))
        nil -> MapSet.new()
      end

    {tracking, refresh} =
      Enum.reduce(removed, {tracking, []}, fn id, {t, refresh} ->
        if MapSet.member?(leaving, id),
          do: {%{t | departing: Map.put(t.departing, id, t.last[id])}, [id | refresh]},
          else: {forget(t, id), [id | refresh]}
      end)

    # Departed entities whose handoff cleared.
    {tracking, refresh} =
      Enum.reduce(tracking.departing, {tracking, refresh}, fn {id, _}, {t, refresh} ->
        if MapSet.member?(leaving, id) or is_map_key(views, id),
          do: {t, refresh},
          else: {forget(t, id), [id | refresh]}
      end)

    Enum.reduce(changed, {tracking, refresh}, fn id, {t, refresh} ->
      view = views[id]
      native = match?(%NativeBody{}, Map.get(view, :body))

      t =
        cond do
          native and is_map_key(t.natives, id) ->
            %{t | departing: Map.delete(t.departing, id)}

          not native and is_map_key(t.trackers, id) ->
            %{t | departing: Map.delete(t.departing, id)}

          true ->
            start(forget(t, id), id, view, native)
        end

      {%{t | pending: MapSet.put(t.pending, id)}, [id | refresh]}
    end)
  end

  defp forget(t, id),
    do: %{
      t
      | trackers: Map.delete(t.trackers, id),
        natives: Map.delete(t.natives, id),
        spawns: Map.delete(t.spawns, id),
        departing: Map.delete(t.departing, id),
        pending: MapSet.delete(t.pending, id)
    }

  defp start(t, id, view, true) do
    {x, y, z} = view.at
    {vx, vy, vz} = view.velocity
    angle = &Valimc.Protocol.EntityPackets.angle/1

    fresh =
      <<id::32-signed, x::float-64, y::float-64, z::float-64, vx::float-64, vy::float-64,
        vz::float-64, if(view.on_ground, do: 1, else: 0), angle.(view.yaw), angle.(view.pitch),
        angle.(view.head_yaw)>>

    native = %{
      base: view.at,
      incarnation: System.unique_integer([:positive, :monotonic]),
      event_seq: last_event(view),
      shown: view.body.shown
    }

    %{
      t
      | natives: Map.put(t.natives, id, native),
        spawns: Map.put(t.spawns, id, View.spawn(view, view.at, view.velocity)),
        fresh: [fresh | t.fresh]
    }
  end

  defp start(t, id, view, false) do
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

    %{
      t
      | trackers: Map.put(t.trackers, id, tracker),
        spawns: Map.put(t.spawns, id, View.spawn(view, view.at, view.velocity))
    }
  end

  defp last_event(%{events: [_ | _] = events}), do: events |> List.last() |> elem(0)
  defp last_event(_view), do: 0

  defp new_events(view, after_seq),
    do: for({seq, packet} <- view.events, seq > after_seq, do: packet)

  # The trackers of entities in simulated chunks and of those whose view
  # changed since the last tick: `{tracking, frame, respawned ids}`.
  defp tick_trackers(tracking, views, simulated, native, mask) do
    pending = tracking.pending

    # Without simulated chunks only the changed ones tick.
    candidates =
      if MapSet.size(simulated) == 0,
        do:
          for(id <- pending, tracker = tracking.trackers[id], tracker != nil, do: {id, tracker}),
        else: tracking.trackers

    {trackers, spawns, frame, respawned} =
      Enum.reduce(candidates, {tracking.trackers, tracking.spawns, [], []}, fn
        {id, tracker}, {trackers, spawns, frame, respawned} = acc ->
          case views do
            %{^id => view} ->
              if MapSet.member?(pending, id) or MapSet.member?(simulated, view.chunk) do
                {next, packets} = tick(tracker, view)

                {spawns, respawned} =
                  if next.base != tracker.base or next.movement != tracker.movement or
                       next.rotation != tracker.rotation or next.head != tracker.head,
                     do:
                       {Map.put(spawns, id, View.spawn(view, next.base, next.movement)),
                        [id | respawned]},
                     else: {spawns, respawned}

                frame = if packets == [], do: frame, else: [encode(id, packets) | frame]
                {Map.put(trackers, id, next), spawns, frame, respawned}
              else
                acc
              end

            _ ->
              acc
          end
      end)

    tracking = %{tracking | trackers: trackers, spawns: spawns}

    {tracking, native_frame, native_respawned} =
      tick_natives(tracking, views, native, mask, simulated)

    {%{tracking | pending: MapSet.new()}, [frame | native_frame], respawned ++ native_respawned}
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

  defp tick_natives(tracking, _views, nil, _mask, _simulated), do: {tracking, [], []}

  defp tick_natives(%{natives: natives} = tracking, _views, _native, _mask, _simulated)
       when natives == %{},
       do: {%{tracking | fresh: []}, [], []}

  # A native mob whose view changed is named to its section with its new
  # entity events and data changes, unless it only moved in a simulated
  # chunk, where its tracker ticks anyway.
  defp tick_natives(tracking, views, native, mask, simulated) do
    {natives, run} =
      Enum.reduce(tracking.pending, {tracking.natives, []}, fn id, {natives, run} = acc ->
        with %{^id => stub} <- natives, %{^id => view} <- views do
          seq = last_event(view)
          events = if seq == stub.event_seq, do: [], else: new_events(view, stub.event_seq)
          shown = view.body.shown

          changes =
            if shown == stub.shown or shown == nil or stub.shown == nil,
              do: [],
              else: NativeBody.shown_changes(id, %NativeBody{shown: stub.shown}, view.body)

          natives =
            if seq == stub.event_seq and shown === stub.shown,
              do: natives,
              else: Map.put(natives, id, %{stub | event_seq: seq, shown: shown})

          if events == [] and changes == [] and MapSet.member?(simulated, view.chunk) do
            {natives, run}
          else
            {natives,
             [
               {id, IO.iodata_to_binary(encode(id, events)),
                IO.iodata_to_binary(encode(id, changes))}
               | run
             ]}
          end
        else
          _ -> acc
        end
      end)

    fresh = tracking.fresh |> Enum.reverse() |> IO.iodata_to_binary()

    if mask == 0 and run == [] and fresh == <<>> do
      {%{tracking | natives: natives, fresh: []}, [], []}
    else
      {frame, spawns} =
        NativeMobs.track(native, mask, fresh, run, packet_ids_cached())

      {natives, spawned, respawned} = respawn(spawns, natives, tracking.spawns, [])

      {%{tracking | natives: natives, spawns: spawned, fresh: []}, frame, respawned}
    end
  end

  defp packet_ids_cached do
    case :persistent_term.get({__MODULE__, :packet_ids}, nil) do
      nil ->
        ids = packet_ids()
        :persistent_term.put({__MODULE__, :packet_ids}, ids)
        ids

      ids ->
        ids
    end
  end

  @add_entity elem(Packets.packet("add_entity", <<>>), 0)

  # A tracker the section started itself is a new incarnation: observers
  # resync to it.
  defp respawn(
         <<id::32-signed, started, x::float-64, y::float-64, z::float-64, size::32,
           payload::binary-size(size), rest::binary>>,
         natives,
         spawns,
         respawned
       ) do
    case natives do
      %{^id => stub} ->
        stub =
          if started == 1,
            do: %{stub | incarnation: System.unique_integer([:positive, :monotonic])},
            else: stub

        respawn(
          rest,
          Map.put(natives, id, %{stub | base: {x, y, z}}),
          Map.put(spawns, id, {@add_entity, payload}),
          [id | respawned]
        )

      _ ->
        respawn(rest, natives, spawns, respawned)
    end
  end

  defp respawn(<<>>, natives, spawns, respawned), do: {natives, spawns, respawned}

  # Projects `ids` again: `{tracking, changed chunks}`.
  defp refresh(tracking, views, ids) do
    Enum.reduce(ids, {tracking, %{}}, fn id, {t, chunks} ->
      view = Map.get(views, id) || Map.get(t.departing, id)
      old = t.published[id]

      case view do
        nil ->
          {%{t | published: Map.delete(t.published, id)} |> unindex(id, old), touch(chunks, old)}

        view ->
          observed = observed(view, t.spawns[id], info(t, id), old)

          cond do
            observed == old ->
              {t, chunks}

            old != nil and old.chunk == observed.chunk ->
              {%{t | published: Map.put(t.published, id, observed)},
               Map.put(chunks, observed.chunk, true)}

            true ->
              t = %{t | published: Map.put(t.published, id, observed)} |> unindex(id, old)
              t = %{t | chunks: Map.update(t.chunks, observed.chunk, [id], &[id | &1])}
              {t, chunks |> touch(old) |> Map.put(observed.chunk, true)}
          end
      end
    end)
  end

  defp refresh_players(tracking, players, chunks) when players === tracking.players,
    do: {tracking, chunks}

  defp refresh_players(tracking, players, chunks) do
    old = tracking.players

    gone = for {id, _} <- old, not is_map_key(players, id), do: id

    {t, chunks} =
      Enum.reduce(gone, {tracking, chunks}, fn id, {t, chunks} ->
        prior = t.published[id]

        {%{t | published: Map.delete(t.published, id)} |> unindex(id, prior),
         touch(chunks, prior)}
      end)

    {t, chunks} =
      Enum.reduce(players, {t, chunks}, fn {id, view}, {t, chunks} ->
        prior = t.published[id]

        if prior == view do
          {t, chunks}
        else
          t = %{t | published: Map.put(t.published, id, view)} |> unindex(id, prior)
          t = %{t | chunks: Map.update(t.chunks, view.chunk, [id], &[id | &1])}
          {t, chunks |> touch(prior) |> Map.put(view.chunk, true)}
        end
      end)

    {%{t | players: players}, chunks}
  end

  defp touch(chunks, nil), do: chunks
  defp touch(chunks, %{chunk: chunk}), do: Map.put(chunks, chunk, true)

  defp unindex(t, _id, nil), do: t

  defp unindex(t, id, %{chunk: chunk}) do
    case t.chunks do
      %{^chunk => [^id]} -> %{t | chunks: Map.delete(t.chunks, chunk)}
      %{^chunk => ids} -> %{t | chunks: Map.put(t.chunks, chunk, List.delete(ids, id))}
      _ -> t
    end
  end

  defp rows(t, chunks, tick) do
    Map.new(chunks, fn {chunk, _} ->
      row =
        t.chunks
        |> Map.get(chunk, [])
        |> Map.new(fn id -> {id, Map.put(t.published[id], :tick, tick)} end)

      {chunk, row}
    end)
  end

  # The tracker's base and incarnation, which rows carry.
  defp info(t, id) do
    case t.trackers do
      %{^id => tracker} -> {tracker.base, tracker.incarnation}
      _ -> {t.natives[id].base, t.natives[id].incarnation}
    end
  end

  @doc "What observers read of entity `id` (its row view, without `tick`), or nil."
  def published(tracking, id), do: tracking.published[id]

  @doc "Every row view, by id."
  def published(tracking), do: tracking.published

  @doc "One frame (a map of each entity's packets) as frame entries."
  def encode_frame(frame) when frame == %{}, do: []
  def encode_frame(frame), do: Enum.map(frame, fn {id, packets} -> encode(id, packets) end)

  @doc "Entity `id`'s `packets` as frame entries (iodata)."
  def encode(id, packets) do
    Enum.map(packets, fn {packet, payload} ->
      payload = IO.iodata_to_binary(payload)
      [<<id::32-signed, packet::16, byte_size(payload)::32>> | payload]
    end)
  end

  @doc "The packets of a frame binary as `[{entity id, {packet id, payload}}]` (tests)."
  def decode(<<id::32-signed, packet::16, size::32, payload::binary-size(size), rest::binary>>),
    do: [{id, {packet, payload}} | decode(rest)]

  def decode(<<>>), do: []

  # What observers read: only the fields connections use, with the spawn,
  # the base it is at and the tracker's incarnation (`tracker`). An item's
  # `pickup_delay` is 0 once it can be picked up, else 1, so a delay
  # counting down does not rewrite its row every tick. A body that only
  # moved keeps the rest of its projection.
  defp observed(view, spawn, {base, incarnation}, old) do
    case old do
      %{kind: kind, type: type, tracker: ^incarnation}
      when kind in [:mob, :object] and type == :erlang.map_get(:type, view) ->
        if moved_only?(view, old),
          do: moved(old, view, spawn, base),
          else: project(view, spawn, base, incarnation)

      _ ->
        project(view, spawn, base, incarnation)
    end
  end

  # Only the physical fields of a native mob's row changed (its section
  # mirrored a move): the rest of the projection stands.
  defp moved_only?(%{body: %NativeBody{} = body, alive: alive, metadata: metadata} = view, old),
    do:
      old.alive == alive and old.metadata === metadata and old.epoch == view.epoch and
        old.ownership_generation == view.ownership_generation and
        not Map.has_key?(old, :dragon_parts) and body.type not in ["minecraft:shulker"]

  defp moved_only?(_view, _old), do: false

  defp moved(old, view, spawn, base) do
    %{
      old
      | chunk: view.chunk,
        at: view.at,
        velocity: view.velocity,
        on_ground: view.on_ground,
        yaw: view.yaw,
        pitch: view.pitch,
        box: Valimc.Entity.Body.box(view.body, view.at),
        spawn: spawn,
        base: base
    }
  end

  defp project(view, spawn, base, incarnation) do
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

    common = Map.merge(common, %{spawn: spawn, base: base, tracker: incarnation})

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
    |> Map.put(:collider, collider(view.body, view.at))
    |> Map.put(:range, Valimc.Data.EntityTypes.tracking_range(view.type))
    |> takeable(view)
    |> multipart(view)
  end

  defp collider(%Valimc.Entity.NativeBody{} = row, at),
    do: Valimc.Entity.NativeBody.collider(row, at)

  defp collider(_body, _at), do: nil

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

  # A trident too, and one with Loyalty on its way back (`ThrownTrident.tryPickup`:
  # its owner only, which the owner checks).
  defp takeable(fields, %{type: "minecraft:trident", body: %{data: data}}) do
    Map.put(
      fields,
      :takeable,
      (data.in_ground and data.shake <= 0 and data.pickup != :disallowed) or
        Map.get(data, :returning, false)
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
