defmodule Valimc.Connection do
  use GenServer, restart: :temporary, shutdown: 15_000

  @moduledoc """
  A socket-owning process per player: framing, encryption, compression, login
  and configuration, then in play the chunk view and replication while its
  session runs at the player's group (`Valimc.Session.Link`,
  `Valimc.Session.Host`). It stays the player's address throughout.
  """
  require Logger

  alias Valimc.Protocol.{ClientTick, Wire}

  alias Valimc.Session.Jobs
  alias Valimc.Session.Messages
  alias Valimc.Net.Serverbound
  alias Valimc.Player.CreativeInventory

  import Valimc.Net.Codec,
    only: [reject: 2, reset_window: 1]

  alias Valimc.{ChatThrottle, CreativeInput, Inventory, Metrics}

  alias Valimc.World.{ChestLidReplication, EntityReplication}
  import Bitwise
  @live_effects Valimc.Living.Effects.live()
  @doc "Status effects the live game applies; others are refused (login, commands)."
  def live_effects, do: @live_effects

  # Before configuration a client sends only small frames (VMC-077a): the
  # handshake and status are a few hundred bytes, login its name, key and
  # cookie answers (at most 5 KiB) and the first configuration packets behind
  # them. Configuration and play keep `:max_packet_bytes`.
  @small_frames %{handshake: 1024, status: 1024, login: 32_768}
  # A connection's heap beyond this is a defect or an attack: it is killed
  # (VMC-077a). A player measured about 110 KB at view distance 2.
  @max_heap_bytes 64 * 1024 * 1024

  @doc "The largest inbound frame (and receive buffer) the connection's phase accepts."
  def frame_limit(%{phase: phase}),
    do: Map.get(@small_frames, phase) || Valimc.config(:max_packet_bytes)

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @doc "Server-authorized relocation; expires rather than applying an abandoned queued call."
  def teleport(pid, destination) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:teleport, destination, deadline}, 1500)
  end

  @doc "Set a bounded server-authorized velocity without replacing the accepted position."
  def set_velocity(pid, velocity) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:set_velocity, velocity, deadline}, 1500)
  end

  @doc "Apply server-authorized fall damage on its player owner; landing validation is separate."
  def fall_damage(pid, amount) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:fall_damage, amount, deadline}, 1500)
  end

  @doc "Apply a supported effect on its player owner; duration state is bounded and server-authorized."
  def add_effect(pid, effect_id, incoming) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:effect, effect_id, incoming, deadline}, 1500)
  end

  @impl true
  # A playing session's calls (`Valimc.Session.Calls`) go to its owner, which
  # answers the caller; before play the connection holds the session itself.
  def handle_call(message, _from, %{owner: owner} = state)
      when owner != nil and (message == :debug_state or elem(message, 0) == :debug_update) do
    case GenServer.call(owner, {:player_call, state.player.uuid, message}, 30_000) do
      %{} = session -> {:reply, Map.merge(state, Map.delete(session, :socket)), state}
      _gone -> {:reply, state, state}
    end
  end

  def handle_call(message, from, %{owner: owner} = state) when owner != nil do
    send(owner, {:"$gen_call", from, {:player_call, state.player.uuid, message}})
    {:noreply, state}
  end

  def handle_call(message, _from, state) do
    case Valimc.Session.Calls.call(message, state) do
      {:stop, reason, reply, next} -> {:stop, reason, reply, next}
      {:reply, reply, next} -> {:reply, reply, next}
    end
  end

  def deliver(pid, event) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} ->
        if size <= Valimc.config(:max_mailbox) do
          send(pid, {:event, event})
          :ok
        else
          # First sender only: ask for a graceful stop (terminate/2 saves), and kill
          # it if it is too stuck to handle the signal.
          if :ets.insert_new(Valimc.OverloadedConnections, {pid}) do
            Metrics.add(:slow_clients_disconnected)
            Process.exit(pid, {:shutdown, :overloaded})
            :timer.kill_after(Valimc.config(:overload_kill_ms), pid)
          end

          :overloaded
        end

      nil ->
        :closed
    end
  end

  @impl true
  def init(socket) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    Process.flag(:max_heap_size, %{
      size: div(@max_heap_bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: true
    })

    {:ok,
     %{
       socket: socket,
       # The player's stable address: timers, replies and deliveries come here.
       connection: self(),
       # The group hosting the session in play (`Valimc.Session.Host`).
       owner: nil,
       owner_monitor: nil,
       phase: :handshake,
       step: nil,
       threshold: nil,
       protocol: nil,
       buffer: <<>>,
       cipher: nil,
       encryption_requested: Valimc.config(:encrypt_login) or Valimc.config(:online_mode),
       online_mode: Valimc.config(:online_mode),
       login_name: nil,
       key_challenge: nil,
       key_pair: nil,
       key_public: nil,
       key_job: nil,
       auth_job: nil,
       player: nil,
       client_tick: %ClientTick{},
       chat_throttle: ChatThrottle.new(),
       # The player's durability (`Valimc.Player.Storage`), from login on.
       storage: nil,
       active_use: nil,
       mining: nil,
       mining_water: false,
       table_menu: nil,
       chest_lids: %ChestLidReplication{},
       table_counter: 0,
       life_stage: :alive,
       # A dimension change waiting for the old dimension's work (VMC-026b).
       travel: nil,
       # Portal contact and process (`Valimc.Player.Portals`, VMC-026b2).
       portal: nil,
       respawn_requested: false,
       experience_after: System.monotonic_time(:millisecond),
       pickup_cursor: 0,
       creative_input: CreativeInput.new(CreativeInventory.creative_tick()),
       chunks: MapSet.new(),
       regions: MapSet.new(),
       # Region => owner told which chunks the view wants (VMC-075).
       wanted: %{},
       pending: [],
       # Vanilla refills the quota in the tick a player joins (VMC-070).
       chunk_sender: Valimc.Session.ChunkSender.tick(%Valimc.Session.ChunkSender{}),
       # Vanilla's default until the client sends its settings (VMC-070).
       requested_view_distance: 2,
       player_flags_view: 0,
       equipment_source: nil,
       pose_checked: nil,
       pose_generation: 0,
       pose_sources: %{},
       jobs: Jobs.new(),
       motion_window: nil,
       simulation_clock: nil,
       # `:manual` (tests): only explicit `{:player_tick, token}` messages tick (VMC-073).
       player_ticks: :timer,
       movement_speed_view: nil,
       absorption_view: nil,
       jump_boost_view: nil,
       food_tick_origin: 0,
       simulation_due: false,
       air_policy: :none,
       environment_effects: %{},
       fire_damage_due: false,
       fire_contacts_active: false,
       armor_view: nil,
       entity_replication: EntityReplication.new(),
       entity_cache: %{},
       clock_version: nil,
       weather_view: nil,
       difficulty_view: nil,
       border_view: nil,
       outbound: [],
       # Admission derives permissions from the server-selected or saved mode.
       inventory: Inventory.new(),
       window: System.monotonic_time(:second),
       packets: 0,
       bytes: 0,
       logical_bytes: 0,
       keepalive: nil,
       # VMC-010c: the last player action (`ServerPlayer.lastActionTime`), for the idle kick.
       last_action: System.monotonic_time(:millisecond),
       teleport: 1,
       teleport_pending: true,
       login_velocity_pending: false,
       view: nil,
       active: false
     }}
  end

  @impl true
  # In play the session runs at its owner and the connection keeps its own
  # messages (`Valimc.Session.Link`); before that it runs the session itself.
  def handle_info(message, %{owner: owner} = state) when owner != nil,
    do: Valimc.Session.Link.info(message, state)

  def handle_info(message, state), do: Messages.dispatch(message, state)

  @doc false
  def guard_connection(state, work) do
    work.()
  rescue
    exception ->
      # Malformed input and server defects both end the session; never silently.
      Metrics.add(:malformed_connections)

      Logger.warning(
        "Connection closed after exception: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:stop, :normal, state}
  catch
    {:disconnect, _reason, current} -> {:stop, :normal, current}
    {:disconnect, _reason} -> {:stop, :normal, state}
  end

  @doc false
  def consume(%{step: step} = state, _) when step in [:key_job, :auth_job],
    do: {:noreply, %{state | active: false}}

  def consume(state, 0) do
    send(self(), :drain)
    {:noreply, state}
  end

  def consume(state, remaining) do
    # Leave the exception boundary before recursing so the 64-packet drain does
    # not grow a stack of guards. A failed frame retains earlier accepted state.
    case guard_connection(state, fn -> consume_packet(state) end) do
      {:continue, next} -> consume(next, remaining - 1)
      result -> result
    end
  end

  defp consume_packet(state) do
    case Wire.next_frame(state.buffer, frame_limit(state), state.threshold) do
      :more ->
        :ok = :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | active: true}}

      {:error, _} ->
        reject(state, "Malformed packet")

      {:ok, id, payload, tail} ->
        state = reset_window(state)
        logical_bytes = state.logical_bytes + byte_size(payload)

        if logical_bytes > Valimc.config(:bytes_per_second),
          do: reject(state, "Decoded byte rate exceeded")

        state = %{state | logical_bytes: logical_bytes}

        if state.packets >= Valimc.config(:packets_per_second),
          do: reject(state, "Packet rate exceeded")

        Metrics.add(:packets_received)

        state =
          Serverbound.handle_packet(
            %{state | buffer: tail, packets: state.packets + 1},
            id,
            payload
          )

        {:continue, state}
    end
  end

  def offline_uuid(name) do
    <<a::48, b::16, c::16, d::48>> = :crypto.hash(:md5, "OfflinePlayer:" <> name)
    <<a::48, (b &&& 0x0FFF) ||| 0x3000::16, (c &&& 0x3FFF) ||| 0x8000::16, d::48>>
  end

  @impl true
  def terminate(reason, state) do
    Valimc.Session.Presence.left(state, reason)
    :gen_tcp.close(state.socket)
    stop_login_jobs(state)

    case state do
      # The session at its owner saves and leaves before the connection ends.
      %{owner: owner} when owner != nil ->
        try do
          GenServer.call(owner, {:player_left, state.player.uuid, reason}, 15_000)
        catch
          :exit, _ -> Logger.error("Player state final save could not complete")
        end

      # Before play the connection holds the session itself.
      %{jobs: %Jobs{}} ->
        Messages.terminate(state)

      _ ->
        :ok
    end
  end

  defp stop_login_jobs(state) do
    if state.key_job do
      Process.cancel_timer(state.key_job.timer)
      Process.demonitor(state.key_job.monitor, [:flush])
      Valimc.KeyExchange.cancel(state.key_job)
    end

    if state.auth_job do
      Process.cancel_timer(state.auth_job.timer)
      Process.demonitor(state.auth_job.monitor, [:flush])
      Valimc.Auth.SessionJobs.cancel(state.auth_job)
    end
  end
end
