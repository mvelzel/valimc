defmodule Valimc.Player.Host do
  @moduledoc """
  The players a group hosts (VMC-077i3). The group that owns the section a
  player stands in holds its session: body, inventory, living state, menus,
  movement, mining and item use. The player's connection keeps the socket and
  the view and stays the player's address: what is meant for the session
  arrives there and is forwarded here as `{:player, uuid, message}`.

  - **Callbacks.** A session message runs the same handlers a connection ran
    (`Valimc.Session.Messages`), in the player's dimension. What the session
    sends goes to the connection after the callback as one
    `{:player_out, items}`: frames, view changes and view resets in order.
    Calls to the group itself run inline (`Valimc.World.Region.call/3`).
  - **Moves.** A player that steps into a section of another group, or into
    another dimension, is handed to that section's group once it is loaded;
    one whose section moves to another group (a merge or split) goes along.
    The adopting group tells the connection, so the connection's later
    messages follow the adoption; what still reaches the old group is
    forwarded for #{120} s.
  - **Replication.** Each hosted player has a tracker in the group
    (`Valimc.World.PlayerTracker`): every tick the section the player stands
    in publishes its row and the packets of what changed, beside its items
    and orbs, for observers' connections to read (`track/1`).
  - **Durability.** Each hosted player's changes are a frame of this
    group's commit (`Valimc.Player.Storage`), with the world's. A player is
    handed on only once its frames are sent, so the changes of one callback
    never split between two groups' records.
  - **Ends.** A session that stops (a rejected packet, a defect) tells its
    connection to close; a connection that closes or dies has its session
    end. Either way its last frame is cut at once, and once it is durable the
    player file holds it and this group lets the player go: a connection
    that asked is answered then.

  Process-bound pieces of a session (task replies, monitors, job timers) come
  to the group that made them; the session that claims one handles it, and an
  unclaimed one follows the players this group handed on.
  """
  alias Valimc.Data.Grid
  require Logger
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Player.Storage
  alias Valimc.Protocol.Codec
  alias Valimc.Session.Messages
  alias Valimc.World
  alias Valimc.World.PlayerTracker

  @group {__MODULE__, :group}
  @acting {__MODULE__, :acting}
  @forward_ms 120_000

  ## Inline calls (inside a callback)

  @doc """
  Run `fun` on the hosting group's state (`fun.(state) -> {reply, state}`)
  while a session callback runs; `:none` outside one.
  """
  def inline(fun) do
    case Process.get(@group) do
      nil ->
        :none

      state ->
        {reply, state} = fun.(state)
        Process.put(@group, state)
        {:ok, reply}
    end
  end

  @doc "The connection a running session callback acts for, or nil."
  def acting, do: Process.get(@acting)

  ## Group side

  @doc """
  Host `session` (a connection's login, or a handoff from the group `from`,
  which lets the player go once this one holds it): `state`.
  """
  def host(state, session, from \\ nil) do
    uuid = session.player.uuid
    monitor = Process.monitor(session.connection)
    :ok = Storage.hold(session.storage)
    if from, do: send(from, {:player_held, uuid})

    entry = %{
      session: session,
      key: key(session.player),
      monitor: monitor,
      view: view(session),
      tracker: PlayerTracker.new(session.player)
    }

    state = %{state | players: Map.put(state.players, uuid, entry)}
    state = %{state | player_moves: Map.delete(state.player_moves, uuid)}
    relocate(state, uuid)
  end

  @doc "A session's message (`{:player, uuid, message}`)."
  def info(state, uuid, message) do
    case state.players do
      %{^uuid => _} -> run(state, uuid, &Messages.dispatch(message, &1))
      _ -> forward(state, uuid, {:player, uuid, message})
    end
  end

  @doc "A session's call (`{:player_call, uuid, message}`), answered to `from`."
  def call(state, uuid, message, from) do
    case state.players do
      %{^uuid => _} ->
        run(state, uuid, fn session ->
          case Valimc.Player.Calls.call(message, session) do
            {:reply, reply, next} ->
              GenServer.reply(from, reply)
              {:noreply, next}

            {:stop, reason, reply, next} ->
              GenServer.reply(from, reply)
              {:stop, reason, next}
          end
        end)

      _ ->
        case state.player_moves do
          %{^uuid => {pid, _}} ->
            send(pid, {:"$gen_call", from, {:player_call, uuid, message}})

          _ ->
            GenServer.reply(from, {:error, :not_playing})
        end

        state
    end
  end

  @doc """
  The connection of `uuid` closed (`reason`): its session ends and saves;
  `reply` (the connection's call) is answered once the file holds it.
  """
  def left(state, uuid, reason, reply \\ nil) do
    case state.players do
      %{^uuid => entry} ->
        Process.demonitor(entry.monitor, [:flush])
        run(state, uuid, fn session -> {:stop, {:left, reason, reply}, session} end)

      _ ->
        if reply, do: GenServer.reply(reply, :ok)
        state
    end
  end

  @doc "The group `uuid` was handed to holds its state: this one lets it go."
  def held(state, uuid) do
    unless Map.has_key?(state.players, uuid) or Map.has_key?(state.player_leaving, uuid),
      do: Registry.unregister(Valimc.PlayerRegistry, uuid)

    state
  end

  ## Replication

  @doc """
  Each hosted player's tracker ticks once: `{state, published}`, what each
  of this group's sections publishes of the players standing in it,
  `%{key => {views, frame}}`.
  """
  def track(state) do
    Enum.reduce(state.players, {state, %{}}, fn {uuid, entry}, {acc, published} ->
      if home?(acc, entry) do
        player = entry.session.player
        {tracker, packets} = PlayerTracker.tick(entry.tracker, player)
        acc = put_in(acc.players[uuid].tracker, tracker)
        epoch = acc.sections[entry.key].resource.epoch

        case PlayerTracker.view(
               tracker,
               player,
               entry.session.connection,
               epoch,
               tracker.incarnation
             ) do
          nil ->
            {acc, published}

          view ->
            {views, frame} = Map.get(published, entry.key, {%{}, %{}})
            frame = if packets == [], do: frame, else: Map.put(frame, player.entity_id, packets)
            {acc, Map.put(published, entry.key, {Map.put(views, player.entity_id, view), frame})}
        end
      else
        {acc, published}
      end
    end)
  end

  ## Durability (the group's commit)

  @doc """
  Cut each hosted player's changes into its storage; a player whose state
  the file may not hold stops.
  """
  def cut(state) do
    Enum.reduce(state.players, state, fn {uuid, %{session: session} = entry}, acc ->
      case Storage.cut(session.storage, capture(session)) do
        {:ok, storage} ->
          put_in(acc.players[uuid].session.storage, storage)

        {:error, reason} ->
          Logger.error("Player state cannot be saved: #{inspect(reason)}")
          Process.demonitor(entry.monitor, [:flush])
          send(session.connection, {:player_stop, "Player save failed"})
          leave(acc, uuid, session, nil, false)
      end
    end)
  end

  @doc "Whether a player's frames wait to be sent."
  def pending?(state), do: Enum.any?(storages(state), fn {_, _, s} -> s.outbox != [] end)

  @doc "Whether a player's frames are in flight."
  def in_flight?(state), do: Enum.any?(storages(state), fn {_, _, s} -> s.in_flight != %{} end)

  @doc "Whether a player's frames are still in flight on another stripe than `route`'s."
  def held?(state, route),
    do: Enum.any?(storages(state), fn {_, _, s} -> Storage.held?(s, route) end)

  @doc """
  Every player's frames to send on `route`'s stripe, as `{base, frame}`, and
  the state that sent them.
  """
  def take(state, route) do
    Enum.reduce(storages(state), {[], state}, fn {place, uuid, storage}, {frames, acc} ->
      {taken, storage} = Storage.take(storage, route)

      {frames ++ for(frame <- taken, do: {storage.base, frame}),
       put_storage(acc, place, uuid, storage)}
    end)
  end

  @doc """
  A frame of `uuid` is durable: a leaving player whose last frame it was
  closes; the acknowledgement of a player handed on follows it.
  """
  def durable(state, uuid, seq) do
    case place(state, uuid) do
      {place, storage} ->
        {storage, items} = Storage.durable(storage, seq)
        state = put_storage(state, place, uuid, storage)
        Enum.reduce(items, state, fn {:close, reply}, acc -> close(acc, uuid, reply) end)

      nil ->
        forward(state, uuid, {:storage_durable, {:player, uuid}, seq})
    end
  end

  @doc "Players whose checkpoint is due write it, off the group."
  def checkpoints(state) do
    Enum.reduce(state.players, state, fn {uuid, %{session: session}}, acc ->
      if Storage.checkpoint_due?(session.storage),
        do:
          put_in(acc.players[uuid].session.storage, Storage.checkpoint(session.storage, self())),
        else: acc
    end)
  end

  @doc "A player's checkpoint finished (`{:player_checkpointed, uuid, ref, seq, result}`)."
  def checkpointed(state, uuid, ref, seq, result) do
    case place(state, uuid) do
      {place, storage} ->
        put_storage(state, place, uuid, Storage.checkpointed(storage, ref, seq, result))

      nil ->
        forward(state, uuid, {:player_checkpointed, uuid, ref, seq, result})
    end
  end

  @doc "A leaving player's file holds its last frame: the group lets it go."
  def closed(state, uuid) do
    state = %{state | player_leaving: Map.delete(state.player_leaving, uuid)}
    unless Map.has_key?(state.players, uuid), do: Registry.unregister(Valimc.PlayerRegistry, uuid)
    state
  end

  defp capture(session), do: PlayerState.capture(session.player, session.inventory)

  defp storages(state) do
    for({uuid, entry} <- state.players, do: {:players, uuid, entry.session.storage}) ++
      for {uuid, storage} <- state.player_leaving, do: {:player_leaving, uuid, storage}
  end

  defp place(state, uuid) do
    case state do
      %{players: %{^uuid => entry}} -> {:players, entry.session.storage}
      %{player_leaving: %{^uuid => storage}} -> {:player_leaving, storage}
      _ -> nil
    end
  end

  defp put_storage(state, :players, uuid, storage),
    do: put_in(state.players[uuid].session.storage, storage)

  defp put_storage(state, :player_leaving, uuid, storage),
    do: put_in(state.player_leaving[uuid], storage)

  # The session is gone: its last frame (`final`) is cut now, and the file
  # takes it once it is durable.
  defp leave(state, uuid, session, reply, final) do
    storage =
      with true <- final,
           {:ok, storage} <- Storage.cut(session.storage, capture(session), true) do
        storage
      else
        _ -> session.storage
      end

    state = %{
      state
      | players: Map.delete(state.players, uuid),
        player_leaving: Map.put(state.player_leaving, uuid, storage)
    }

    case Storage.after_durable(storage, {:close, reply}) do
      {:now, storage} -> close(put_in(state.player_leaving[uuid], storage), uuid, reply)
      {:later, storage} -> put_in(state.player_leaving[uuid], storage)
    end
  end

  defp close(state, uuid, reply) do
    :ok = Storage.close(state.player_leaving[uuid], self(), reply)
    state
  end

  @doc "Whether `uuid`'s session moved on from here: its new group, or nil."
  def moved(state, uuid) do
    case state.player_moves do
      %{^uuid => {pid, _}} -> pid
      _ -> nil
    end
  end

  @doc """
  A process-bound message (a task reply, a DOWN, a job timer): `{:ok, state}`
  once a session claimed it or it went on to a group this one handed players
  to, `:error` otherwise. A connection's DOWN ends its session.
  """
  def claim(state, message, hops \\ 0)

  def claim(state, {:DOWN, ref, :process, _, reason} = message, hops) do
    case Enum.find(state.players, fn {_, entry} -> entry.monitor == ref end) do
      {uuid, _} -> {:ok, left(state, uuid, reason)}
      nil -> claim_session(state, message, hops)
    end
  end

  def claim(state, message, hops), do: claim_session(state, message, hops)

  defp claim_session(state, message, hops) do
    case Enum.find(state.players, fn {_, entry} -> Messages.claims?(entry.session, message) end) do
      {uuid, _} ->
        {:ok, run(state, uuid, &Messages.dispatch(message, &1))}

      nil when hops < 2 and state.player_moves != %{} ->
        for pid <- state.player_moves |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
            do: send(pid, {:player_claim, hops + 1, message})

        {:ok, state}

      nil ->
        :error
    end
  end

  @doc "Players standing in `keys` go with them to `target` (a handoff of sections)."
  def give(state, keys, target) do
    keys = MapSet.new(keys)

    state.players
    |> Enum.filter(fn {_, entry} ->
      entry.session.player.dimension == state.dimension and MapSet.member?(keys, entry.key)
    end)
    |> Enum.reduce(state, fn {uuid, _}, acc -> hand(acc, uuid, target) end)
  end

  @doc "Players not in a section of this group try to reach their section's group."
  def tick(state) do
    state.players
    |> Enum.reject(fn {_, entry} -> home?(state, entry) end)
    |> Enum.reduce(state, fn {uuid, _}, acc -> relocate(acc, uuid) end)
    |> expire_moves()
  end

  @doc """
  A clean stop: every hosted session ends and its last frame is cut; the
  group sends them (`commit/1`, its commit) and waits until they are
  appended (`sync/1`), then writes the files (`close_all/1`).
  """
  def stop_all(state, commit) do
    state = Enum.reduce(Map.keys(state.players), state, &left(&2, &1, :shutdown))
    state = commit.(state)

    for {_, _, %{base: base}} when base != nil <- storages(state),
        do: Valimc.Storage.Log.sync(base, state.route)

    for {uuid, storage} <- state.player_leaving do
      Storage.close_now(storage)
      Registry.unregister(Valimc.PlayerRegistry, uuid)
    end

    %{state | player_leaving: %{}}
  end

  ## Callbacks

  defp run(state, uuid, fun) do
    %{session: session} = entry = state.players[uuid]
    group_dimension = Valimc.World.Dimension.put(session.player.dimension)
    Codec.open_outbox()
    Process.put(@group, state)
    Process.put(@acting, session.connection)

    result =
      try do
        fun.(session)
      rescue
        exception ->
          Logger.warning(
            "Hosted session stopped after exception: " <>
              Exception.format(:error, exception, __STACKTRACE__)
          )

          {:stop, :normal, session}
      catch
        {:disconnect, _reason, current} -> {:stop, :normal, current}
        {:disconnect, _reason} -> {:stop, :normal, session}
      after
        Valimc.World.Dimension.put(group_dimension)
        Process.delete(@acting)
      end

    state = Process.delete(@group)

    case result do
      {:noreply, session} ->
        settle(state, uuid, entry, session)

      {:stop, reason, session} ->
        finish(state, uuid, entry, session, reason)
    end
  end

  defp settle(state, uuid, entry, session) do
    view = view(session)
    if view != entry.view, do: Codec.out({:view, view})
    flush(session)
    entry = %{entry | session: session, view: view}
    state = %{state | players: Map.put(state.players, uuid, entry)}
    if entry.key == key(session.player), do: state, else: relocate(state, uuid)
  end

  # The session ends here and saves; a connection that is still open is told
  # to close with the reason the session recorded.
  defp finish(state, uuid, entry, session, reason) do
    group_dimension = Valimc.World.Dimension.put(session.player.dimension)
    Process.put(@group, state)
    Process.put(@acting, session.connection)

    session =
      try do
        Messages.terminate(session)
      rescue
        exception ->
          Logger.error(
            "Hosted session end failed: " <> Exception.format(:error, exception, __STACKTRACE__)
          )

          session
      after
        Valimc.World.Dimension.put(group_dimension)
        Process.delete(@acting)
      end

    state = Process.delete(@group)
    Process.demonitor(entry.monitor, [:flush])

    case reason do
      {:left, _, reply} ->
        Codec.take_outbox()
        leave(state, uuid, session, reply, true)

      _ ->
        flush(session)
        send(session.connection, {:player_stop, Codec.take_reason()})
        leave(state, uuid, session, nil, true)
    end
  end

  defp flush(session) do
    case Codec.take_outbox() do
      [] -> :ok
      nil -> :ok
      items -> send(session.connection, {:player_out, Enum.reverse(items)})
    end
  end

  # What the connection's view reads of the player.
  defp view(session) do
    player = session.player

    %{
      x: player.x,
      y: player.y,
      z: player.z,
      yaw: player.yaw,
      pitch: player.pitch,
      dimension: player.dimension,
      spectator: player.game_mode.current == :spectator,
      teleport_pending: session.teleport_pending
    }
  end

  ## Moves

  defp key(player),
    do: Grid.region_key(Grid.chunk_key(player.x, player.z))

  defp home?(state, entry),
    do:
      entry.session.player.dimension == state.dimension and
        Map.has_key?(state.sections, entry.key)

  # A player in a section of another group goes there once that group exists.
  defp relocate(state, uuid) do
    entry = state.players[uuid]
    key = key(entry.session.player)
    state = put_in(state.players[uuid].key, key)

    if home?(state, %{entry | key: key}) do
      state
    else
      section = Grid.section(entry.session.player.dimension, key, :section)

      case World.existing_owner(section) do
        {:ok, {pid, _}} when pid != self() -> handoff(state, uuid, pid)
        _ -> state
      end
    end
  end

  # The player's changes and the world's go out in one record first; a commit
  # held by frames still in flight elsewhere defers the move to a later tick.
  defp handoff(state, uuid, target) do
    state = Valimc.World.Region.commit_now(state)

    case state.players do
      %{^uuid => %{session: %{storage: %{outbox: []}}}} -> hand(state, uuid, target)
      _ -> state
    end
  end

  defp hand(state, uuid, target) do
    {entry, players} = Map.pop(state.players, uuid)
    Process.demonitor(entry.monitor, [:flush])
    send(target, {:adopt_player, entry.session, self()})
    until = System.monotonic_time(:millisecond) + @forward_ms
    Valimc.Data.Metrics.add(:player_handoffs)

    %{
      state
      | players: players,
        player_moves: Map.put(state.player_moves, uuid, {target, until})
    }
  end

  defp forward(state, uuid, message) do
    case state.player_moves do
      %{^uuid => {pid, _}} -> send(pid, message)
      _ -> :ok
    end

    state
  end

  defp expire_moves(%{player_moves: moves} = state) when moves == %{}, do: state

  defp expire_moves(state) do
    now = System.monotonic_time(:millisecond)
    %{state | player_moves: Map.filter(state.player_moves, fn {_, {_, until}} -> until > now end)}
  end
end
