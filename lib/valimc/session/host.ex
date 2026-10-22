defmodule Valimc.Session.Host do
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
  - **Ends.** A session that stops (a rejected packet, a defect) saves and
    tells its connection to close; a connection that closes or dies has its
    session saved and dropped.

  Process-bound pieces of a session (task replies, monitors, job timers) come
  to the group that made them; the session that claims one handles it, and an
  unclaimed one follows the players this group handed on.
  """
  require Logger
  alias Valimc.Session.Messages
  alias Valimc.World

  @out {__MODULE__, :out}
  @group {__MODULE__, :group}
  @acting {__MODULE__, :acting}
  @forward_ms 120_000

  ## Output and inline calls (inside a callback)

  @doc "Queue `item` (`{:frames, iodata}`, `{:view, map}`, `{:reset, map}`) for the connection."
  def out(item) do
    case Process.get(@out) do
      nil -> raise ArgumentError, "session output outside a hosted callback"
      items -> Process.put(@out, [item | items])
    end

    :ok
  end

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

  @doc "The connection a running session callback acts for (its player store's owner), or nil."
  def acting, do: Process.get(@acting)

  ## Group side

  @doc "Host `session` (a connection's login, or a handoff): `state`."
  def host(state, session) do
    uuid = session.player.uuid
    monitor = Process.monitor(session.connection)

    store_monitor =
      if is_pid(session.player_store), do: Process.monitor(session.player_store)

    session = %{session | store_monitor: store_monitor}

    entry = %{session: session, key: key(session.player), monitor: monitor, view: view(session)}
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
          case Valimc.Session.Calls.call(message, session) do
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

  @doc "The connection of `uuid` closed (`reason`): its session saves and leaves."
  def left(state, uuid, reason) do
    case state.players do
      %{^uuid => entry} ->
        Process.demonitor(entry.monitor, [:flush])
        state = run(state, uuid, fn session -> {:stop, {:left, reason}, session} end)
        %{state | players: Map.delete(state.players, uuid)}

      _ ->
        state
    end
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

  @doc "A clean stop: every hosted session saves; connections then see the group gone."
  def stop_all(state) do
    Enum.reduce(Map.keys(state.players), state, &left(&2, &1, :shutdown))
  end

  ## Callbacks

  defp run(state, uuid, fun) do
    %{session: session} = entry = state.players[uuid]
    group_dimension = Valimc.Dimension.put(session.player.dimension)
    Process.put(@out, [])
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
        Valimc.Dimension.put(group_dimension)
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
    if view != entry.view, do: out({:view, view})
    flush(session)
    entry = %{entry | session: session, view: view}
    state = %{state | players: Map.put(state.players, uuid, entry)}
    if entry.key == key(session.player), do: state, else: relocate(state, uuid)
  end

  # The session ends here: it saves, and a connection that is still open is
  # told to close with the reason the session recorded.
  defp finish(state, uuid, entry, session, reason) do
    group_dimension = Valimc.Dimension.put(session.player.dimension)
    Process.put(@group, state)
    Process.put(@acting, session.connection)

    try do
      Messages.terminate(session)
    rescue
      exception ->
        Logger.error(
          "Hosted session save failed: " <> Exception.format(:error, exception, __STACKTRACE__)
        )
    after
      Valimc.Dimension.put(group_dimension)
      Process.delete(@acting)
    end

    state = Process.delete(@group)
    Process.demonitor(entry.monitor, [:flush])
    if session.store_monitor, do: Process.demonitor(session.store_monitor, [:flush])

    case reason do
      {:left, _} ->
        Process.delete(@out)

      _ ->
        flush(session)
        send(session.connection, {:player_stop, Valimc.Session.Presence.take()})
    end

    %{state | players: Map.delete(state.players, uuid)}
  end

  defp flush(session) do
    case Process.delete(@out) do
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
      teleport_pending: session.teleport_pending
    }
  end

  ## Moves

  defp key(player), do: World.region_key(World.chunk_key(player.x, player.z))

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
      section = World.section(entry.session.player.dimension, key, :section)

      case World.existing_owner(section) do
        {:ok, {pid, _}} when pid != self() -> hand(state, uuid, pid)
        _ -> state
      end
    end
  end

  defp hand(state, uuid, target) do
    {entry, players} = Map.pop(state.players, uuid)
    Process.demonitor(entry.monitor, [:flush])
    session = entry.session
    if session.store_monitor, do: Process.demonitor(session.store_monitor, [:flush])
    send(target, {:adopt_player, %{session | store_monitor: nil}})
    until = System.monotonic_time(:millisecond) + @forward_ms
    Valimc.Metrics.add(:player_handoffs)

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
