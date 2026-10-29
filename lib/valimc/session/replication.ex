defmodule Valimc.Session.Replication do
  @moduledoc "What a connection's client sees: view distance, chunk streaming and the world's views (VMC-069, VMC-070)."

  alias Valimc.Data.Grid

  alias Valimc.Protocol.{
    Packets,
    Wire
  }

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, send_frames: 2]

  alias Valimc.World

  alias Valimc.World.{
    BorderReplication,
    ChestLidReplication,
    Region,
    WeatherReplication
  }

  alias Valimc.Session.ChunkSender
  alias Valimc.Player.ChunkView
  alias Valimc.Worldgen.Scheduler

  @doc """
  Track the chunks of the player's current view (VMC-070): its chunk and the
  distance its client requested, clamped to the server's. Leaving chunks the
  client has are forgotten, pending ones dropped; entering ones wait for
  `stream_chunks/1`, nearest first.
  """
  def update_view(state) do
    {center, _} =
      view =
      {Grid.chunk_key(state.player.x, state.player.z),
       ChunkView.distance(state.requested_view_distance)}

    arena = dragon_arena?(state)

    if view == state.view do
      if arena == Map.get(state, :dragon_arena, false),
        do: state,
        else: state |> Map.put(:dragon_arena, arena) |> want_chunks()
    else
      {entering, leaving} = ChunkView.difference(state.view, view)
      forgotten = Enum.filter(leaving, &MapSet.member?(state.chunks, &1))
      moved = state.view == nil or elem(state.view, 0) != center

      send_packets(
        state,
        if(moved, do: [Packets.center(center)], else: []) ++
          Enum.map(forgotten, &Packets.unload/1)
      )

      regions = ChunkView.regions(view, state.player.dimension)
      World.subscribe(regions, state.regions)
      chunks = MapSet.difference(state.chunks, MapSet.new(forgotten))
      leaving = MapSet.new(leaving)
      {cx, cz} = center

      pending =
        Enum.reject(state.pending, &MapSet.member?(leaving, &1))
        |> Enum.concat(entering)
        |> Enum.sort_by(fn {x, z} -> (x - cx) * (x - cx) + (z - cz) * (z - cz) end)

      send(self(), :send_chunks)

      %{
        state
        | view: view,
          regions: regions,
          chunks: chunks,
          chest_lids: ChestLidReplication.retain(state.chest_lids, chunks),
          pending: pending,
          chunk_sender: ChunkSender.forget(state.chunk_sender, leaving)
      }
      |> Map.put(:dragon_arena, arena)
      |> focus()
      |> want_chunks()
    end
  end

  # The generation scheduler hears the player's chunk and heading straight
  # from here at every chunk it enters (VMC-077u): its own chunk and the
  # chunks ahead go first, and the regions' tickets, which wait in their
  # owners' mailboxes, need not change to reorder anything.
  @jump 64.0
  defp dragon_arena?(%{player: %{dimension: :the_end} = player} = state) do
    alive = Map.get(player, :alive, Map.get(state, :life_stage) == :alive)
    Valimc.World.Dragon.Fight.eligible?(%{alive: alive, x: player.x, y: player.y, z: player.z})
  end

  defp dragon_arena?(_state), do: false

  defp focus(%{view: {center, _}, player: player} = state) do
    dimension = player.dimension
    position = {player.x, player.z}

    case Map.get(state, :generation_focus) do
      {^dimension, ^center, _} ->
        state

      previous ->
        world = fn chunk -> Valimc.config(:world_path, Grid.region_key(chunk)) end

        heading =
          case previous do
            {^dimension, old, {x, z}} ->
              # Another world's scheduler only in tests' private worlds.
              if world.(old) != world.(center),
                do: Scheduler.focus(world.(old), dimension, self(), nil, nil)

              {dx, dz} = {player.x - x, player.z - z}
              length = :math.sqrt(dx * dx + dz * dz)
              if length > 0 and length <= @jump, do: {dx / length, dz / length}

            {other, old, _} ->
              Scheduler.focus(world.(old), other, self(), nil, nil)
              nil

            nil ->
              nil
          end

        Scheduler.focus(world.(center), dimension, self(), center, heading)
        Map.put(state, :generation_focus, {dimension, center, position})
    end
  end

  # The player's tickets (VMC-077e, VMC-077e1): the chunks within the
  # simulation distance (Chebyshev, at most the server's view distance) tick
  # (`:player_simulation`) whatever the client renders, as vanilla's do; the
  # view and those chunks load (`:player_loading`, generated nearest to the
  # player first, VMC-075). Regions are admitted nearest first, as vanilla's
  # player tickets load (VMC-071). An owner told before that is no longer the
  # one of its key (the view left it, it restarted, or the player changed
  # dimension) withdraws. `wanted` remembers which owner was told.
  defp want_chunks(%{view: {{cx, cz}, _} = view} = state) do
    reach = min(Valimc.config(:simulation_distance), ChunkView.server_distance())
    local = for x <- (cx - reach)..(cx + reach), z <- (cz - reach)..(cz + reach), do: {x, z}

    arena =
      if Map.get(state, :dragon_arena, false), do: Valimc.World.Dragon.Arena.chunks(), else: []

    simulation = Enum.uniq(local ++ arena)
    simulated_chunks = MapSet.new(simulation)

    loading =
      view
      |> ChunkView.chunks()
      |> Enum.concat(Enum.reject(simulation, &ChunkView.contains?(view, &1)))
      |> Enum.group_by(&Grid.region_key/1)

    size = Grid.region_size()

    {wanted, tickets} =
      loading
      |> Enum.sort_by(fn {{rx, rz}, _} ->
        (rx * size + div(size, 2) - cx) ** 2 + (rz * size + div(size, 2) - cz) ** 2
      end)
      |> Enum.map_reduce(%{}, fn {key, chunks}, tickets ->
        section = Grid.section(state.player.dimension, key, :section)

        case World.region(section) do
          {:ok, pid} ->
            simulated = Enum.filter(chunks, &MapSet.member?(simulated_chunks, &1))

            told = {pid, MapSet.new(chunks), MapSet.new(simulated)}

            # Only a section whose chunks changed is told again: the
            # player's focus orders generation (VMC-077u), and a view of
            # distance 32 spans about 80 sections.
            if Map.get(state.wanted, section) == told do
              {{section, told}, tickets}
            else
              entries = [
                {key, :player_simulation, simulated},
                {key, :player_loading, chunks}
              ]

              {{section, told}, Map.update(tickets, pid, entries, &(entries ++ &1))}
            end

          # Not reachable now (admitting, or moving between groups): who was
          # told last still holds the tickets, to withdraw them later.
          _ ->
            {{section, Map.get(state.wanted, section)}, tickets}
        end
      end)

    wanted = Map.new(wanted)

    # A section that moved to another group took the tickets with it
    # (VMC-077j): only sections the view left (or of the dimension the player
    # left) are told to drop them, at the group holding them now (the one told
    # may have retired since).
    tickets =
      for {section, {told, _, _}} <- state.wanted,
          not Map.has_key?(wanted, section),
          reduce: tickets do
        acc ->
          {_, key} = Grid.split_section(section)
          entries = [{key, :player_loading, []}, {key, :player_simulation, []}]

          pid =
            case World.Directory.lookup(section) do
              {pid, _, _} -> pid
              nil -> told
            end

          Map.update(acc, pid, entries, &(&1 ++ entries))
      end

    # One message per group, nearest sections first.
    for {pid, entries} <- tickets, do: Region.tickets(pid, Enum.reverse(entries))

    watch_owners(%{state | wanted: wanted})
  end

  # The groups told the view's wants are watched (VMC-077y): one that stops
  # took them along, and its sections load again once told again.
  defp watch_owners(state) do
    pids = for {_, {pid, _, _}} <- state.wanted, into: MapSet.new(), do: pid

    {kept, gone} =
      Map.split_with(state.wanted_owners, fn {pid, _} -> MapSet.member?(pids, pid) end)

    for {_, ref} <- gone, do: Process.demonitor(ref)

    owners =
      Enum.reduce(pids, kept, fn pid, acc ->
        Map.put_new_lazy(acc, pid, fn ->
          :erlang.monitor(:process, pid, tag: :wanted_owner_down)
        end)
      end)

    %{state | wanted_owners: owners}
  end

  @doc "A group told the view's wants stopped (`pid`): the view tells its sections again."
  def owner_down(state, pid) do
    state = %{state | wanted_owners: Map.delete(state.wanted_owners, pid)}
    if match?({_, _}, state.view), do: want_chunks(state), else: state
  end

  @doc "A 50 ms tick of the chunk stream: refill the send quota, then stream."
  def chunk_tick(state),
    do: stream_chunks(%{state | chunk_sender: ChunkSender.tick(state.chunk_sender)})

  @doc """
  Send the nearest pending chunks the quota allows as one batch; chunks whose
  region is still loading stay pending. A chunk's packet is read from its
  owner's publication, or requested and sent once the reply came (VMC-077e):
  the connection never waits. Nothing streams before the client confirms its
  play teleport.
  """
  def stream_chunks(%{phase: :play, teleport_pending: false, pending: [_ | _]} = state) do
    case ChunkSender.batch_size(state.chunk_sender) do
      0 ->
        state

      size ->
        # The nearest chunks that are ready, as vanilla sends from loaded ones.
        {ready, sender} =
          state.pending
          |> then(&World.sendable(state.player.dimension, &1, size))
          |> Enum.reduce({[], state.chunk_sender}, fn
            {chunk, {:frame, frame}}, {ready, sender} ->
              {[{chunk, frame} | ready], sender}

            {chunk, {:owner, pid}}, {ready, sender} ->
              case ChunkSender.take(sender, chunk) do
                {:ok, frame, sender} -> {[{chunk, frame} | ready], sender}
                :error -> {ready, ChunkSender.request(sender, chunk, pid)}
              end
          end)

        state = %{state | chunk_sender: sender}
        if ready == [], do: state, else: send_batch(state, Enum.reverse(ready))
    end
  end

  def stream_chunks(state), do: state

  @doc """
  A message that may answer a chunk request: `{:ok, state}` (streaming what is
  now ready) or `:error` when it is not one.
  """
  def chunk_reply(state, message) do
    case ChunkSender.response(state.chunk_sender, message) do
      {:ok, chunk, sender} ->
        sender = if chunk in state.pending, do: sender, else: ChunkSender.forget(sender, [chunk])
        {:ok, stream_chunks(%{state | chunk_sender: sender})}

      :error ->
        :error
    end
  end

  defp send_batch(state, ready) do
    {chunk_frames, lids} =
      Enum.map_reduce(ready, state.chest_lids, fn {chunk, frame}, lids ->
        case World.chest_lid_snapshot(state.player.dimension, chunk) do
          {:ok, owner, positions, lid_frame} ->
            lids = Enum.reduce(positions, lids, &ChestLidReplication.observe(&2, owner, &1, true))
            accepted = Enum.filter(positions, &(lids.positions[&1] == owner))

            lid_frame =
              if accepted == positions,
                do: lid_frame,
                else:
                  Enum.map(accepted, &Packets.frame(Packets.chest_lid(&1, true), state.threshold))

            {[frame, lid_frame], lids}

          :empty ->
            {frame, lids}
        end
      end)

    frames =
      [Packets.frame(Packets.packet("chunk_batch_start", <<>>), state.threshold)] ++
        chunk_frames ++
        [
          Packets.frame(
            Packets.packet("chunk_batch_finished", Wire.varint(length(ready))),
            state.threshold
          )
        ]

    send_frames(state, frames)
    sent = MapSet.new(ready, &elem(&1, 0))

    %{
      state
      | pending: Enum.reject(state.pending, &MapSet.member?(sent, &1)),
        chunks: MapSet.union(state.chunks, sent),
        chest_lids: lids,
        chunk_sender: ChunkSender.sent(state.chunk_sender, length(ready))
    }
  end

  @doc """
  Whether the player sees an entity at `{x, z}` whose type vanilla tracks `range`
  chunks away (VMC-070): within `min(range, view distance)` chunks horizontally,
  in a tracked chunk. Vanilla also waits until that chunk was sent; entities
  and players here are tracked only in sent chunks (`entity_chunks/2`).
  """
  def sees?(%{view: {_, distance} = view} = state, {x, z}, range) do
    limit = 16 * min(range, distance)
    dx = x - state.player.x
    dz = z - state.player.z

    dx * dx + dz * dz <= limit * limit and
      ChunkView.contains?(view, Grid.chunk_key(x, z))
  end

  def sees?(_state, _at, _range), do: false

  @doc "The sent chunks that may hold entities tracked `range` chunks away."
  def entity_chunks(%{view: {_, distance}} = state, range) do
    limit = 16 * min(range, distance)
    %{x: x, z: z} = state.player
    {cx0, cz0} = Grid.chunk_key(x - limit, z - limit)
    {cx1, cz1} = Grid.chunk_key(x + limit, z + limit)

    for cx <- cx0..cx1,
        cz <- cz0..cz1,
        MapSet.member?(state.chunks, {cx, cz}),
        square_distance({x, z}, {cx, cz}) <= limit * limit,
        do: {cx, cz}
  end

  def entity_chunks(_state, _range), do: []

  @doc "Reuse the candidate chunks while the player's position and sent view are unchanged."
  def cached_entity_chunks(state, range) do
    key = {state.view, state.chunks, state.player.x, state.player.z, range}

    case Map.get(state, :entity_chunks_cache) do
      {^key, chunks} ->
        {chunks, state}

      _ ->
        chunks = entity_chunks(state, range)
        {chunks, Map.put(state, :entity_chunks_cache, {key, chunks})}
    end
  end

  # From `{x, z}` to the nearest point of a chunk, squared.
  defp square_distance({x, z}, {cx, cz}) do
    dx = x - (x |> max(cx * 16) |> min(cx * 16 + 16))
    dz = z - (z |> max(cz * 16) |> min(cz * 16 + 16))
    dx * dx + dz * dz
  end

  @doc "Queue `packets` for the connection's next write."
  def buffer(state, packets), do: %{state | outbound: [packets | state.outbound]}

  @doc """
  The world's clocks, weather, border and difficulty as the client last saw
  them: what changed goes into the outbound buffer.
  """
  def replicate_world(state) do
    {version, clock_packet} = Valimc.World.Clock.publication()

    state =
      if version != state.clock_version,
        do: %{state | clock_version: version, outbound: [clock_packet | state.outbound]},
        else: state

    {weather_view, weather_packets} =
      WeatherReplication.reconcile(state.weather_view, Valimc.World.Clock.weather())

    state = buffer(%{state | weather_view: weather_view}, weather_packets)

    {border_view, border_packets} =
      BorderReplication.reconcile(state.border_view, Valimc.World.Clock.border())

    state = buffer(%{state | border_view: border_view}, border_packets)
    {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()

    if state.difficulty_view != difficulty,
      do: buffer(%{state | difficulty_view: difficulty}, [difficulty_packet]),
      else: state
  end
end
