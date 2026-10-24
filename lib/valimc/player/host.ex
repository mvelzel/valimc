defmodule Valimc.Player.Host do
  @moduledoc """
  The players a group hosts (VMC-077i3). The group that owns the section a
  player stands in holds its session: body, inventory, living state, menus,
  movement, mining and item use. The player's connection keeps the socket and
  the view and stays the player's address: what is meant for the session
  arrives there and is forwarded here as `{:player, uuid, message}`.

  - **Callbacks.** A session message runs its session's router, the module
    under the session's `:router` key that implements this module's callbacks
    (`Valimc.Session.Messages`), in the player's dimension. What the session
    sends goes to the connection after the callback as one
    `{:player_out, items}`: frames, view changes and view resets in order.
    Calls to the group itself run inline (`Valimc.World.Region.call/3`).
  - **Moves.** The group's one transfer (`Valimc.World.Region`, VMC-077y)
    moves a player with its section, or alone into another group's section,
    once no session job runs. Until the target holds it, what arrives for it
    goes on and a copy is kept; if the target stops first, it resumes here
    and runs the copies (`resume/2`). What arrives for a player hosted
    elsewhere goes to its host (`Valimc.Player.Storage.host/1`).
  - **Replication.** Each hosted player has a tracker in the group
    (`Valimc.World.PlayerTracker`): every tick the section the player stands
    in publishes its row and the packets of what changed, beside its items
    and orbs, for observers' connections to read (`track/1`).
  - **Durability.** Each hosted player's changes are a frame of this
    group's commit (`Valimc.Player.Storage`), with the world's.
  - **Ends.** A session that stops (a rejected packet, a defect) tells its
    connection to close; a connection that closes or dies has its session
    end. Either way its last frame is cut at once, and once it is durable the
    player file holds it and this group lets the player go: a connection
    that asked is answered then.

  A player is registered under its uuid exactly while a group hosts it or
  saves its last frame (`Valimc.Player.Storage.hold/1` and `release/1`).
  """
  @doc "Route a message the session's group received (its jobs first)."
  @callback dispatch(message :: term, session :: map) ::
              {:noreply, map} | {:stop, term, map}

  @doc "Whether a process-bound message (a task reply, a DOWN, a job timer) is the session's."
  @callback claims?(session :: map, message :: term) :: boolean

  @doc "Whether the session may move to another group: no process-bound work runs."
  @callback movable?(session :: map) :: boolean

  @doc "The session arrived in this group: it watches from here what it watched."
  @callback adopted(session :: map) :: map

  @doc "The session ends: it releases what it holds and returns the state its last frame saves."
  @callback terminate(session :: map) :: map

  alias Valimc.Data.Grid
  require Logger
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Player.Storage
  alias Valimc.Protocol.Codec
  alias Valimc.World.PlayerTracker

  @group {__MODULE__, :group}
  @acting {__MODULE__, :acting}
  @copies 4_096

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

  @doc "Host `session` (a connection's login, or a transfer's player): `state`."
  def host(state, session) do
    uuid = session.player.uuid
    :ok = Storage.hold(session.storage)
    session = route(session, :adopted, [session])
    send(session.connection, {:player_owner, uuid, self()})

    entry = %{
      session: session,
      key: key(session.player),
      monitor: Process.monitor(session.connection),
      view: view(session),
      tracker: PlayerTracker.new(session.player)
    }

    %{state | players: Map.put(state.players, uuid, entry)}
  end

  @doc "Whether `session`'s player stands in one of this group's sections."
  def home?(state, session),
    do: at_home?(state, %{session: session, key: key(session.player)})

  @doc "A session's message (`{:player, uuid, message}`)."
  def info(state, uuid, message) do
    # A world call may affect players while one of their callbacks is still
    # running. Settle that callback first: recursively running another would
    # overwrite its session, group context and output buffer.
    if acting() != nil do
      pending = Map.get(state, :player_pending, [])
      count = Map.get(state, :player_pending_count, 0)
      if count >= @copies, do: raise("too many player effects in one callback")

      state
      |> Map.put(:player_pending, [{uuid, message} | pending])
      |> Map.put(:player_pending_count, count + 1)
    else
      deliver(state, uuid, {:player, uuid, message}, {:info, message}, fn state ->
        run(state, uuid, &route(&1, :dispatch, [message, &1]))
      end)
    end
  end

  @doc "A session's call (`{:player_call, uuid, message}`), answered to `from`."
  def call(state, uuid, message, from) do
    call = {:"$gen_call", from, {:player_call, uuid, message}}

    deliver(state, uuid, call, {:call, message, from}, fn state ->
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
    end)
  end

  @doc """
  The connection of `uuid` closed (`reason`): its session ends and saves;
  `reply` (the connection's call) is answered once the file holds it.
  """
  def left(state, uuid, reason, reply \\ nil) do
    # The target of a move watches the connection itself; a call goes on.
    call = if reply, do: {:"$gen_call", reply, {:player_left, uuid, reason}}

    deliver(state, uuid, call, {:left, reason, reply}, fn state ->
      Process.demonitor(state.players[uuid].monitor, [:flush])
      run(state, uuid, fn session -> {:stop, {:left, reason, reply}, session} end)
    end)
  end

  # A message for `uuid`: run here, passed on with a move, or sent to the
  # group hosting the player (a stray).
  defp deliver(state, uuid, message, item, hosted) do
    cond do
      Map.has_key?(state.players, uuid) ->
        hosted.(state)

      ref = moving(state, uuid) ->
        pass(state, ref, uuid, message, item)

      pid = message && Storage.host(uuid) ->
        send(pid, message)
        state

      true ->
        drop(item, state)
    end
  end

  ## Replication

  @doc """
  Each hosted player's tracker ticks once: `{state, published}`, what each
  of this group's sections publishes of the players standing in it,
  `%{key => {views, frame}}`.
  """
  def track(state) do
    Enum.reduce(state.players, {state, %{}}, fn {uuid, entry}, {acc, published} ->
      if at_home?(acc, entry) do
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

  @doc """
  What mobs' AI senses of this group's players (VMC-041a): every living,
  non-spectator player in the group's dimension as `Valimc.AI.World`
  describes a sensed player.
  """
  def sensed(state) do
    for {uuid, %{session: %{player: player} = session}} <- state.players,
        player.dimension == state.dimension and session.life_stage == :alive and
          player.game_mode.current != :spectator do
      pose = Map.get(player, :pose, :standing)
      {:ok, dimensions} = Valimc.Data.PlayerPose.dimensions(pose)
      inventory = session.inventory
      item = fn slot -> (stack = Valimc.Menus.Inventory.get(inventory, slot)) && stack.item_id end
      armor = for slot <- 5..8, item.(slot) != nil, do: slot
      effects = player.living.effects

      %{
        kind: :player,
        uuid: uuid,
        id: player.entity_id,
        x: player.x * 1.0,
        y: player.y * 1.0,
        z: player.z * 1.0,
        yaw: player.yaw * 1.0,
        pitch: player.pitch * 1.0,
        eye: dimensions["eye_height"] * 1.0,
        width: dimensions["width"] * 1.0,
        height: dimensions["height"] * 1.0,
        mode: player.game_mode.current,
        invulnerable: player.game_mode.current == :creative,
        alive: true,
        crouching: pose == :crouching,
        # `isSwimming` (a dolphin swims along, VMC-043e).
        swimming: Map.get(player.motion, :swimming, false) == true,
        invisible:
          Valimc.Living.Attributes.amplifier(effects, Valimc.Data.EffectTypes.id("invisibility")) !=
            nil,
        armor_cover: Valimc.Data.Float32.round(length(armor) / 4),
        # What a lead it holds pulls with (VMC-043c3, `getKnownMovement`).
        movement: player.motion.known_movement,
        # What a witch reads of its target (VMC-043b6): its motion, health
        # and effects.
        velocity: player.motion.velocity,
        health: player.living.health.value,
        effects: MapSet.new(Map.keys(effects)),
        equipment: %{
          mainhand: item.(36 + inventory.selected),
          offhand: item.(45),
          head: item.(5),
          chest: item.(6),
          legs: item.(7),
          feet: item.(8)
        }
      }
    end
  end

  @doc "Every alive player of this group's dimension, including spectators, for boss audiences."
  def boss_players(state) do
    for {uuid, %{session: %{player: player, life_stage: :alive}}} <- state.players,
        player.dimension == state.dimension,
        do: %{uuid: uuid, alive: true, x: player.x, y: player.y, z: player.z}
  end

  @doc """
  The players orbs follow (VMC-077i): every living, non-spectator player in
  this group's dimension, as `{feet, aim}`, `aim` at half its eye height.
  """
  def targets(state) do
    for {_, %{session: %{player: player} = session}} <- state.players,
        player.dimension == state.dimension and session.life_stage == :alive and
          player.game_mode.current != :spectator do
      {_, eye_y, _} = Valimc.Living.Interaction.eye(player)
      {{player.x, player.y, player.z}, {player.x, (player.y + eye_y) / 2, player.z}}
    end
  end

  @doc """
  The players projectiles hit (VMC-037o): every living, non-spectator player
  in this group's dimension, as `%{uuid, id, position, box}`.
  """
  def bodies(state) do
    for {_, %{session: %{player: player} = session}} <- state.players,
        player.dimension == state.dimension and session.life_stage == :alive and
          player.game_mode.current != :spectator,
        {:ok, %{box: box}} <-
          [Valimc.Data.PlayerPose.geometry(player.pose, {player.x, player.y, player.z})] do
      %{
        uuid: player.uuid,
        id: player.entity_id,
        position: {player.x, player.y, player.z},
        box: box
      }
    end
  end

  @doc """
  The players natural spawning reads (VMC-042a): every player of the group's
  dimension, alive or not, as `{x, y, z, spectator, creative}`.
  """
  def spawn_players(state) do
    for {_, %{session: %{player: player}}} <- state.players,
        player.dimension == state.dimension do
      mode = player.game_mode.current
      {player.x * 1.0, player.y * 1.0, player.z * 1.0, mode == :spectator, mode == :creative}
    end
  end

  @doc """
  The group's players as the phantom spawner reads them (VMC-043b6): `{x,
  y, z, spectator, time_since_rest}` in the group's dimension.
  """
  def rest_players(state) do
    for {_, %{session: %{player: player}}} <- state.players,
        player.dimension == state.dimension do
      {player.x * 1.0, player.y * 1.0, player.z * 1.0, player.game_mode.current == :spectator,
       player.time_since_rest}
    end
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

  @doc "Whether frames a player sent are not yet durable."
  def sending?(state), do: Enum.any?(storages(state), fn {_, _, s} -> Storage.sending?(s) end)

  @doc """
  Every player's frames to send on the group's stripe, as `{base, frame}`,
  and the state that sent them.
  """
  def take(state) do
    Enum.reduce(storages(state), {[], state}, fn {place, uuid, storage}, {frames, acc} ->
      {taken, storage} = Storage.take(storage)

      {frames ++ for(frame <- taken, do: {storage.base, frame}),
       put_storage(acc, place, uuid, storage)}
    end)
  end

  @doc "A frame of `uuid` is durable: a leaving player whose last frame it was closes."
  def durable(state, uuid, seq) do
    case place(state, uuid) do
      {place, storage} ->
        {storage, items} = Storage.durable(storage, seq)
        state = put_storage(state, place, uuid, storage)
        Enum.reduce(items, state, fn {:close, reply}, acc -> close(acc, uuid, reply) end)

      nil ->
        state
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
    message = {:player_checkpointed, uuid, ref, seq, result}

    case place(state, uuid) do
      {place, storage} ->
        put_storage(state, place, uuid, Storage.checkpointed(storage, ref, seq, result))

      nil ->
        deliver(state, uuid, message, {:checkpointed, ref, seq, result}, & &1)
    end
  end

  @doc "A leaving player's file holds its last frame: the group lets it go."
  def closed(state, uuid) do
    case Map.pop(state.player_leaving, uuid) do
      {nil, _} ->
        state

      {storage, leaving} ->
        Storage.release(storage)
        %{state | player_leaving: leaving}
    end
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

  @doc """
  A process-bound message (a task reply, a DOWN, a job timer): `{:ok, state}`
  once a session claimed it, `:error` otherwise. A connection's DOWN ends its
  session.
  """
  def claim(state, {:DOWN, ref, :process, _, reason} = message) do
    case Enum.find(state.players, fn {_, entry} -> entry.monitor == ref end) do
      {uuid, _} -> {:ok, left(state, uuid, reason)}
      nil -> claim_session(state, message)
    end
  end

  def claim(state, message), do: claim_session(state, message)

  defp claim_session(state, message) do
    case Enum.find(state.players, fn {_, entry} ->
           route(entry.session, :claims?, [entry.session, message])
         end) do
      {uuid, _} -> {:ok, run(state, uuid, &route(&1, :dispatch, [message, &1]))}
      nil -> :error
    end
  end

  @doc "The routing key of a hosted player's section when it may move there now, or nil."
  def destination(state, uuid) do
    case state.players do
      %{^uuid => %{session: session} = entry} ->
        entry = %{entry | key: key(session.player)}

        if not at_home?(state, entry) and route(session, :movable?, [session]),
          do: Grid.section(session.player.dimension, entry.key, :section)

      _ ->
        nil
    end
  end

  @doc """
  The movable players a transfer takes (`:all`, `{:keys, keys}` or
  `{:players, uuids}`): `{%{uuid => moving}, state}`, connections unwatched.
  """
  def take_players(state, which) do
    {moving, staying} =
      Map.split_with(state.players, fn {uuid, entry} ->
        rides?(state, which, uuid, entry) and route(entry.session, :movable?, [entry.session])
      end)

    for {_, entry} <- moving, do: Process.demonitor(entry.monitor, [:flush])

    {Map.new(moving, fn {uuid, entry} -> {uuid, %{entry: entry, copies: [], size: 0}} end),
     %{state | players: staying}}
  end

  defp rides?(_state, :all, _uuid, _entry), do: true
  defp rides?(_state, {:players, uuids}, uuid, _entry), do: uuid in uuids

  defp rides?(state, {:keys, keys}, _uuid, entry),
    do: entry.session.player.dimension == state.dimension and entry.key in keys

  @doc "The target holds the players of a transfer: this group lets them go."
  def released(moving),
    do: for({_, %{entry: entry}} <- moving, do: Storage.release(entry.session.storage))

  @doc """
  A transfer's target stopped or refused before it held its players, so it
  ran nothing passed on: they are this group's again and run the copies.
  """
  def resume(state, moving) do
    Enum.reduce(moving, state, fn {uuid, %{entry: entry, copies: copies}}, acc ->
      Valimc.Data.Metrics.add(:player_handoffs_resumed)
      session = entry.session
      send(session.connection, {:player_owner, uuid, self()})
      entry = %{entry | monitor: Process.monitor(session.connection)}
      acc = %{acc | players: Map.put(acc.players, uuid, entry)}

      case copies do
        :overflow ->
          Logger.error("Player handoff failed with more than #{@copies} messages waiting")
          Process.demonitor(entry.monitor, [:flush])
          send(session.connection, {:player_stop, "World owner restarted; please reconnect"})
          leave(acc, uuid, session, nil, true)

        copies ->
          copies |> Enum.reverse() |> Enum.reduce(acc, &replay(&2, uuid, &1))
      end
    end)
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

    for {_, storage} <- state.player_leaving do
      Storage.close_now(storage)
      Storage.release(storage)
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

    state =
      case result do
        {:noreply, session} ->
          settle(state, uuid, entry, session)

        {:stop, reason, session} ->
          finish(state, uuid, entry, session, reason)
      end

    pending = Map.get(state, :player_pending, [])
    state = state |> Map.delete(:player_pending) |> Map.delete(:player_pending_count)

    Enum.reduce(Enum.reverse(pending), state, fn {target, message}, acc ->
      info(acc, target, message)
    end)
  end

  # A player that stepped out of the group's sections moves once its
  # section's group exists (`Valimc.World.Region.move_player/2`).
  defp settle(state, uuid, entry, session) do
    view = view(session)
    if view != entry.view, do: Codec.out({:view, view})
    flush(session)
    key = key(session.player)
    entry = %{entry | session: session, view: view, key: key}
    state = %{state | players: Map.put(state.players, uuid, entry)}

    if at_home?(state, entry),
      do: state,
      else: Valimc.World.Region.move_player(state, uuid)
  end

  # The session ends here and saves; a connection that is still open is told
  # to close with the reason the session recorded.
  defp finish(state, uuid, entry, session, reason) do
    group_dimension = Valimc.World.Dimension.put(session.player.dimension)
    Process.put(@group, state)
    Process.put(@acting, session.connection)

    session =
      try do
        route(session, :terminate, [session])
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
      alive: session.life_stage == :alive,
      teleport_pending: session.teleport_pending
    }
  end

  ## Moves

  defp key(player),
    do: Grid.region_key(Grid.chunk_key(player.x, player.z))

  defp at_home?(state, entry),
    do:
      entry.session.player.dimension == state.dimension and
        Map.has_key?(state.sections, entry.key)

  # The transfer `uuid` moves with, or nil.
  defp moving(state, uuid) do
    Enum.find_value(state.transfers, fn {ref, transfer} ->
      if Map.has_key?(transfer.players, uuid), do: ref
    end)
  end

  # What arrives for a moving player goes to the target (`message`, nil when
  # the target learns it itself) and is kept (`item`) until it holds it.
  defp pass(state, ref, uuid, message, item) do
    %{target: target, players: %{^uuid => moving}} = state.transfers[ref]
    if message, do: send(target, message)

    moving =
      cond do
        moving.copies == :overflow -> moving
        moving.size >= @copies -> %{moving | copies: :overflow}
        true -> %{moving | copies: [item | moving.copies], size: moving.size + 1}
      end

    put_in(state.transfers[ref].players[uuid], moving)
  end

  # A replayed message may move the player on again: what follows it is
  # passed on then.
  defp replay(state, uuid, {:info, message}), do: info(state, uuid, message)
  defp replay(state, uuid, {:call, message, from}), do: call(state, uuid, message, from)
  defp replay(state, uuid, {:left, reason, reply}), do: left(state, uuid, reason, reply)

  defp replay(state, uuid, {:checkpointed, ref, seq, result}),
    do: checkpointed(state, uuid, ref, seq, result)

  # A message for a player no longer here: a call is answered as for a
  # player no longer playing.
  defp drop({:call, _, from}, state),
    do: tap(state, fn _ -> GenServer.reply(from, {:error, :not_playing}) end)

  defp drop({:left, _, reply}, state) when reply != nil,
    do: tap(state, fn _ -> GenServer.reply(reply, :ok) end)

  defp drop(_, state), do: state

  # A session's router (its `:router`, the callbacks above).
  defp route(session, callback, args), do: apply(session.router, callback, args)
end
