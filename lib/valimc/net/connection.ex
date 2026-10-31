defmodule Valimc.Net.Connection do
  use GenServer, restart: :temporary, shutdown: 15_000

  @moduledoc """
  A socket-owning process per player: framing, encryption, compression, login
  and configuration, then in play the chunk view and replication while its
  session runs at the player's group (`Valimc.Net.Link`,
  `Valimc.Player.Host`). It stays the player's address throughout.
  """
  require Logger

  alias Valimc.Protocol.{ClientTick, Wire}

  alias Valimc.Player.Jobs
  alias Valimc.Session.Messages
  alias Valimc.Net.Serverbound
  alias Valimc.Player.CreativeInventory

  import Valimc.Protocol.Codec,
    only: [reject: 2, reset_window: 1]

  alias Valimc.Session.ChatThrottle
  alias Valimc.Player.DropThrottle
  alias Valimc.Menus.Inventory
  alias Valimc.Data.Metrics

  alias Valimc.World.ChestLidReplication
  alias Valimc.Entity.Observer

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

  @impl true
  # A playing session's calls (`Valimc.Player.Calls`) go to its owner, which
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
    case Valimc.Player.Calls.call(message, state) do
      {:stop, reason, reply, next} -> {:stop, reason, reply, next}
      {:reply, reply, next} -> {:reply, reply, next}
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
       # The group hosting the session in play (`Valimc.Player.Host`).
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
       # Attack strength (`Valimc.Player.Attack`, VMC-037n).
       attack: %Valimc.Player.Attack{},
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
       creative_input: DropThrottle.new(CreativeInventory.creative_tick()),
       chunks: MapSet.new(),
       # Since when the client lacks the chunk the player is in (`Link`).
       own_chunk_missing: nil,
       regions: MapSet.new(),
       # Section => the owner told which chunks the view wants (VMC-075) and
       # those chunks, loading and simulated (VMC-077u).
       wanted: %{},
       # The groups told, watched: pid => monitor (`Replication`).
       wanted_owners: %{},
       # The dimension, chunk and position the generation scheduler was last
       # told the player is at (VMC-077u).
       generation_focus: nil,
       # The sets the view's tickets want per section (`ViewWants`).
       view_wants: %Valimc.Session.ViewWants{},
       pending: Valimc.Session.PendingChunks.new(),
       # Vanilla refills the quota in the tick a player joins (VMC-070).
       chunk_sender: Valimc.Session.ChunkSender.tick(%Valimc.Session.ChunkSender{}),
       # Vanilla's default until the client sends its settings (VMC-070).
       requested_view_distance: 2,
       player_flags_view: 0,
       effect_particles_view: {[], false},
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
       attack_speed_view: nil,
       effect_attributes_view: nil,
       food_tick_origin: 0,
       simulation_due: false,
       air_policy: :none,
       environment_effects: %{},
       fire_damage_due: false,
       fire_contacts_active: false,
       armor_view: nil,
       entity_replication: Observer.new(),
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
  # messages (`Valimc.Net.Link`); before that it runs the session itself.
  def handle_info(message, %{owner: owner} = state) when owner != nil,
    do: Valimc.Net.Link.info(message, state)

  def handle_info(message, state), do: Valimc.Net.Messages.dispatch(message, state)

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
    case Messages.guard(state, fn -> consume_packet(state) end) do
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

  @impl true
  def terminate(reason, state) do
    Valimc.Player.Presence.left(state, reason)
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
      Valimc.Net.LoginJobs.cancel(state.key_job)
    end

    if state.auth_job do
      Process.cancel_timer(state.auth_job.timer)
      Process.demonitor(state.auth_job.monitor, [:flush])
      Valimc.Net.LoginJobs.cancel(state.auth_job)
    end
  end
end
