defmodule Valimc.Connection do
  use GenServer, restart: :temporary, shutdown: 15_000

  @moduledoc "A socket-owning process per player, including their protocol and connection-local state."
  require Logger

  alias Valimc.Protocol.{
    ClientTick,
    Data,
    EffectTypes,
    Wire
  }

  alias Valimc.Session.Jobs
  alias Valimc.Session.Messages
  alias Valimc.Session.JobHandlers
  alias Valimc.Net.Serverbound
  alias Valimc.Player.Menus
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Transfers
  alias Valimc.Player.Mining
  alias Valimc.Player.Movement
  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [reject: 2, reset_window: 1]

  alias Valimc.{
    ChatThrottle,
    CreativeInput,
    Inventory,
    Metrics,
    Players,
    PlayerHealth,
    PlayerKinetics,
    PlayerSnapshot,
    PlayerStore
  }

  alias Valimc.World.{ChestLidReplication, EntityReplication}
  import Bitwise
  @fire_resistance EffectTypes.id("fire_resistance")
  @resistance EffectTypes.id("resistance")
  @absorption EffectTypes.id("absorption")
  @periodic_effects Enum.sort(Enum.map(~w(regeneration hunger poison wither), &EffectTypes.id/1))
  @live_effects [@fire_resistance, @resistance, @absorption, EffectTypes.id("water_breathing")] ++
                  Enum.map(
                    ~w(speed slowness nausea jump_boost slow_falling levitation),
                    &EffectTypes.id/1
                  ) ++
                  @periodic_effects
  @doc "Status effects the live game applies; others are refused (login, commands)."
  def live_effects, do: @live_effects

  @use_item_packet Data.id(:play, :serverbound, "use_item")
  @slab_tags Path.expand("../../priv/protocol/tags.json", __DIR__)
  @external_resource @slab_tags

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

  @doc "Remove a supported effect on its player owner."
  def remove_effect(pid, effect_id) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:effect, effect_id, :remove, deadline}, 1500)
  end

  @impl true
  def handle_call(
        {:teleport, destination, deadline},
        _,
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and is_map(destination) and
         map_size(destination) == 5 and
         Enum.all?([:x, :y, :z, :yaw, :pitch], &Map.has_key?(destination, &1)) and
         PlayerStore.valid_pose?(destination) do
      {:reply, :ok, Movement.relocate(state, Map.merge(state.player, destination))}
    else
      {:reply, {:error, :invalid_or_expired_teleport}, state}
    end
  end

  def handle_call({:teleport, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call(
        {:set_velocity, velocity, deadline},
        _,
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and PlayerKinetics.valid_velocity?(velocity) and
         PlayerKinetics.admissible?(state.player, velocity) do
      state = state |> Movement.cancel_pose_job() |> Movement.cancel_motion_job()
      velocity = velocity |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()
      motion = %{state.player.motion | velocity: velocity, settled: false}
      player = %{state.player | motion: motion}
      Players.update(self(), player)
      state = %{state | player: player, pose_checked: nil, login_velocity_pending: false}
      state = Movement.send_velocity(state, velocity)
      {:reply, :ok, state |> Movement.start_motion() |> Movement.sample_pose()}
    else
      {:reply, {:error, :invalid_or_expired_velocity}, state}
    end
  end

  def handle_call({:set_velocity, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call({:fall_damage, amount, deadline}, _, %{phase: :play} = state) do
    if System.monotonic_time(:millisecond) < deadline do
      case PlayerHealth.hurt_window(state.player.health, amount) do
        {:ok, selected} ->
          try do
            {result, next} = Vitals.apply_damage(state, selected, :fall)
            {:reply, {:ok, result}, next}
          catch
            {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
          end

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :expired_damage}, state}
    end
  end

  def handle_call({:fall_damage, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call(
        {:effect, id, incoming, deadline},
        _,
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and id in @live_effects do
      try do
        case Valimc.Player.StatusEffects.apply(state, id, incoming) do
          {:ok, changed, next} -> {:reply, {:ok, changed}, next}
          {:error, _} = error -> {:reply, error, state}
        end
      catch
        {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
      end
    else
      {:reply, {:error, :invalid_or_expired_effect}, state}
    end
  end

  def handle_call({:command_op, op, deadline}, _, %{phase: :play} = state) do
    if System.monotonic_time(:millisecond) < deadline do
      try do
        {reply, next} = Valimc.Player.CommandOps.apply(state, op)
        {:reply, {:ok, reply}, next}
      rescue
        exception ->
          Logger.error(
            "Command operation failed: " <> Exception.format(:error, exception, __STACKTRACE__)
          )

          {:reply, {:error, :failed}, state}
      catch
        {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
        {:command_syntax, error} -> {:reply, {:error, error}, state}
      end
    else
      {:reply, {:error, :expired}, state}
    end
  end

  def handle_call({:command_op, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call({:effect, _, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

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

    {:ok,
     %{
       socket: socket,
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
       player_store: nil,
       store_fence: nil,
       store_monitor: nil,
       save_ref: nil,
       use_save: nil,
       active_use: nil,
       mining: nil,
       mining_water: false,
       placement_queue: :queue.new(),
       placement_queued: 0,
       table_menu: nil,
       chest_lids: %ChestLidReplication{},
       table_counter: 0,
       table_job: nil,
       table_queue: :queue.new(),
       table_queued: 0,
       table_closing: false,
       crafting_repeat: nil,
       life_save: nil,
       life_stage: :alive,
       respawn_requested: false,
       recovery: nil,
       experience_after: System.monotonic_time(:millisecond),
       pickup_cursor: 0,
       creative_input: CreativeInput.new(CreativeInventory.creative_tick()),
       creative_drain_scheduled: false,
       chunks: MapSet.new(),
       regions: MapSet.new(),
       pending: [],
       batch_pending: false,
       peers: %{},
       player_flags_view: 0,
       equipment_source: nil,
       pose_checked: nil,
       pose_generation: 0,
       pose_sources: %{},
       jobs: Jobs.new(),
       motion_pending: nil,
       motion_window: nil,
       simulation_clock: nil,
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
       outbound: [],
       # Admission derives permissions from the server-selected or saved mode.
       inventory: Inventory.new(),
       window: System.monotonic_time(:second),
       packets: 0,
       bytes: 0,
       logical_bytes: 0,
       keepalive: nil,
       teleport: 1,
       teleport_pending: true,
       login_velocity_pending: false,
       center: nil,
       active: false
     }}
  end

  @impl true
  # Session jobs (`Valimc.Session.Jobs`) claim their results, DOWNs and timeouts
  # first; everything else goes to the per-message clauses below.
  def handle_info(message, %{jobs: %Jobs{}} = state) do
    case Jobs.classify(state.jobs, message) do
      {:result, kind, job, payload, jobs} ->
        JobHandlers.job_result(kind, job, payload, %{state | jobs: jobs})

      {:down, kind, job, reason, jobs} ->
        JobHandlers.job_down(kind, job, reason, %{state | jobs: jobs})

      {:timeout, kind, job, jobs} ->
        JobHandlers.job_timeout(kind, job, %{state | jobs: jobs})

      :stale ->
        {:noreply, state}

      :unknown ->
        Messages.info(message, state)
    end
  end

  def handle_info(message, state), do: Messages.info(message, state)

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

  # Preserve wire order for movement-dependent interactions and transfers. The
  # socket stays passive while its one input is validated; the owner itself
  # remains responsive to timers, server calls and worker/source messages.
  def consume(%{motion_pending: pending} = state, _) when pending != nil,
    do: {:noreply, state}

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
    case Wire.next_frame(state.buffer, Valimc.config(:max_packet_bytes), state.threshold) do
      :more ->
        :ok = :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | active: true}}

      {:error, _} ->
        reject(state, "Malformed packet")

      # Preserve the client's fallback until its preceding block-use decision.
      # Earlier chat/control frames and owner clocks remain responsive. The
      # bounded receive buffer holds this frame until admission/deadline drains it.
      {:ok, @use_item_packet, _, _}
      when state.phase == :play and state.table_job != nil and state.table_job.kind == :open ->
        {:noreply, state}

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
  def terminate(_reason, state) do
    Menus.retire_container_view(state)
    Menus.cancel_table_query(state)
    Transfers.cancel_pickup_query(state)
    Transfers.cancel_experience_query(state)
    Mining.cancel_mining(state)

    :gen_tcp.close(state.socket)

    if state.motion_pending && state.motion_pending.retry,
      do: Process.cancel_timer(state.motion_pending.retry)

    Jobs.cancel_all(state.jobs)

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

    if state.recovery do
      Process.cancel_timer(state.recovery.timer)
      if state.recovery.retry_timer, do: Process.cancel_timer(state.recovery.retry_timer)

      if state.recovery.job && Process.whereis(Valimc.TransferWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, state.recovery.job.pid)
    end

    if state.player_store && state.phase == :play do
      # Observations can lag quiet simulation clocks. Persist the owner state;
      # per-frame exception boundaries already retain earlier accepted packets.
      snapshot =
        case state.life_save do
          %{kind: :respawn, snapshot: snapshot} ->
            snapshot

          _ ->
            PlayerSnapshot.capture(state.player, state.inventory)
        end

      try do
        PlayerStore.close_session(
          state.player_store,
          state.store_fence,
          snapshot
        )
      catch
        :exit, _ ->
          Logger.error("Player state final save could not complete")
      end
    end
  end
end
