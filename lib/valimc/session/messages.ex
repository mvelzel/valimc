defmodule Valimc.Session.Messages do
  @moduledoc """
  A session's message router (VMC-069): socket data, worker replies, ticks
  and deliveries. Before play the connection runs it
  on its whole state; in play the session's group runs it on the session
  (`Valimc.Player.Host`), and the connection handles only its own messages
  (`Valimc.Session.Link`).
  """

  require Logger

  alias Valimc.Data.EffectTypes
  alias Valimc.Protocol.{Encryption, Packets}

  alias Valimc.Session.{Events, Replication}
  alias Valimc.Player.Jobs
  alias Valimc.Net.LoginFlow
  alias Valimc.Player.{CreativeInventory, Items, ItemUse, Menus, Mining, Movement, Vitals}

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, crypt_bytes: 3, reject: 2, reset_window: 1]

  alias Valimc.Menus.Inventory
  alias Valimc.Data.Metrics
  alias Valimc.Player.Input
  alias Valimc.World
  alias Valimc.World.{ChestLidReplication, TickClock}

  @resistance EffectTypes.id("resistance")
  # Events region owners publish to their visibility topics (`Valimc.World.publish/2`).
  @region_events [
    :block,
    :block_batch,
    :level_events,
    :chest_lid,
    :item_pickup,
    :experience_pickup
  ]

  @doc """
  The session's exception boundary: malformed input and server defects both
  end the session, never silently; a thrown `{:disconnect, ...}` ends it too.
  """
  def guard(state, work) do
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

  @doc "Route `message`: a session job's outcome (`Valimc.Player.Jobs`) or another message."
  def dispatch(message, %{jobs: %Jobs{}} = state) do
    case Jobs.classify(state.jobs, message) do
      {:result, kind, job, payload, jobs} ->
        Valimc.Session.JobHandlers.job_result(kind, job, payload, %{state | jobs: jobs})

      {:down, kind, job, reason, jobs} ->
        Valimc.Session.JobHandlers.job_down(kind, job, reason, %{state | jobs: jobs})

      {:timeout, kind, job, jobs} ->
        Valimc.Session.JobHandlers.job_timeout(kind, job, %{state | jobs: jobs})

      :stale ->
        {:noreply, state}

      :unknown ->
        info(message, state)
    end
  end

  def dispatch(message, state), do: info(message, state)

  @doc """
  Whether a process-bound `message` (a task reply, a DOWN, a job timer) is
  this session's: its group hands it the ones it claims.
  """
  def claims?(session, {:job_timeout, kind, ref}),
    do: match?(%{ref: ^ref}, Jobs.get(session.jobs, kind))

  def claims?(session, {:DOWN, ref, :process, _, _}), do: owns_ref?(session, ref)
  def claims?(session, {ref, _}) when is_reference(ref), do: owns_ref?(session, ref)
  def claims?(_session, _message), do: false

  defp owns_ref?(session, ref) do
    Map.has_key?(session.jobs.refs, ref) or Map.has_key?(session.pose_sources, ref)
  end

  @doc """
  A session ends: its view and jobs are released and the cursor and grid
  drop (vanilla's `removed` of the open menu for a player who disconnected).
  Returns the state its last frame saves (`Valimc.Player.Host`).
  """
  def terminate(state) do
    Menus.retire_container_view(state)
    Jobs.cancel_all(state.jobs)
    if state.phase == :play, do: return_items(%{state | mining: nil}), else: state
  end

  defp return_items(state) do
    with :alive <- state.life_stage,
         {:ok, inventory, stacks} <- Inventory.disconnect(state.inventory),
         {:ok, state} <- Items.drop(state, inventory, stacks) do
      state
    else
      _ -> state
    end
  end

  def info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    Process.send_after(self(), :login_deadline, Valimc.config(:login_timeout_ms))
    Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))
    Metrics.add(:connections_accepted)
    {:noreply, %{state | active: true}}
  end

  def info({:tcp, socket, data}, %{socket: socket} = state) do
    guard(state, fn ->
      state = reset_window(state)
      bytes = state.bytes + byte_size(data)
      if bytes > Valimc.config(:bytes_per_second), do: reject(state, "Inbound byte rate exceeded")

      if byte_size(state.buffer) + byte_size(data) > Valimc.Net.Connection.frame_limit(state) + 5,
        do: reject(state, "Receive buffer exceeded")

      data = crypt_bytes(state.cipher, :decrypt, data)

      Valimc.Net.Connection.consume(
        %{state | buffer: state.buffer <> data, bytes: bytes, active: false},
        64
      )
    end)
  end

  def info(:drain, state),
    do:
      guard(state, fn ->
        Valimc.Net.Connection.consume(state, 64)
      end)

  def info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def info(
        {:key_verified, worker, token, result},
        %{key_job: %{pid: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.Net.KeyExchange.cancel(job)
    state = %{state | key_job: nil}

    guard(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Login encryption timed out")

      case result do
        {:ok, secret} ->
          {:ok, cipher} = Encryption.new(secret)
          # This tail followed the plaintext key frame and has never been decrypted.
          state = %{
            state
            | cipher: cipher,
              buffer: crypt_bytes(cipher, :decrypt, state.buffer),
              step: nil
          }

          if state.online_mode do
            digest = Encryption.server_hash(secret, state.key_public)
            token = make_ref()

            case Valimc.Net.Auth.SessionJobs.start(self(), token, state.login_name, digest) do
              {:ok, job} ->
                timeout = max(job.deadline - System.monotonic_time(:millisecond), 0)
                timer = Process.send_after(self(), {:session_deadline, token}, timeout)
                Valimc.Net.Auth.SessionJobs.activate(job)

                {:noreply,
                 %{
                   state
                   | step: :auth_job,
                     auth_job: Map.put(job, :timer, timer),
                     key_public: nil
                 }}

              _ ->
                reject(state, "Authentication busy; please retry")
            end
          else
            state = LoginFlow.start_player_login(%{state | key_public: nil}, state.login_name)
            Valimc.Net.Connection.consume(state, 64)
          end

        _ ->
          reject(state, "Invalid login encryption response")
      end
    end)
  end

  def info({:key_verified, _, _, _}, state), do: {:noreply, state}

  def info(
        {:session_verified, worker, token, result},
        %{auth_job: %{pid: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.Net.Auth.SessionJobs.cancel(job)
    state = %{state | auth_job: nil}

    guard(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Authentication timed out")

      case result do
        {:ok, profile} ->
          if not Valimc.Net.Auth.Profile.valid?(profile, state.login_name),
            do: reject(state, "Invalid authentication profile")

          state = LoginFlow.start_player_login(%{state | step: nil}, state.login_name, profile)
          Valimc.Net.Connection.consume(state, 64)

        {:error, :unverified_session} ->
          reject(state, "Failed to verify username")

        _ ->
          reject(state, "Authentication servers unavailable; please retry")
      end
    end)
  end

  def info({:session_verified, _, _, _}, state), do: {:noreply, state}

  def info({:session_deadline, token}, %{auth_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do:
        guard(state, fn ->
          reject(state, "Authentication timed out")
        end),
      else: {:noreply, state}
  end

  def info({:session_deadline, _}, state), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{auth_job: %{monitor: ref}} = state),
    do:
      guard(state, fn ->
        reject(state, "Authentication servers unavailable; please retry")
      end)

  def info({:key_deadline, token}, %{key_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do:
        guard(state, fn ->
          reject(state, "Login encryption timed out")
        end),
      else: {:noreply, state}
  end

  def info({:key_deadline, _}, state), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{key_job: %{monitor: ref}} = state),
    do:
      guard(state, fn ->
        reject(state, "Login encryption unavailable")
      end)

  # `/save-all` (VMC-010b): the player's file as soon as its frames are durable.
  def info(:save_player_now, %{storage: %Valimc.Player.Storage{} = storage} = state),
    do: {:noreply, %{state | storage: Valimc.Player.Storage.request_checkpoint(storage)}}

  def info(:save_player_now, state), do: {:noreply, state}

  # Cancelling geometry retires its reference; a result already in this mailbox
  # must never become a new player input or crash a healthy connection.
  def info({ref, _}, state) when is_reference(ref), do: {:noreply, state}

  def info({:DOWN, ref, :process, pid, _} = message, %{socket: socket} = state)
      when socket != nil do
    case Replication.chunk_reply(state, message) do
      {:ok, state} -> {:noreply, state}
      :error -> down(state, ref, pid)
    end
  end

  def info({:DOWN, ref, :process, _, _}, state), do: {:noreply, forget_pose_source(state, ref)}

  # Replies to chunk requests (VMC-077e) are tagged with the request's alias.
  def info({[:alias | ref], _} = message, state) when is_reference(ref) do
    guard(state, fn ->
      case Replication.chunk_reply(state, message) do
        {:ok, state} -> {:noreply, state}
        :error -> {:noreply, state}
      end
    end)
  end

  def info(:login_deadline, %{phase: :play} = state), do: {:noreply, state}
  def info(:login_deadline, state), do: {:stop, :normal, state}

  def info(:keepalive, state) do
    guard(state, fn ->
      Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))

      if state.phase == :play do
        now = System.monotonic_time(:millisecond)
        timeout = Valimc.config(:keepalive_timeout_ms)

        idle = Valimc.World.Settings.get(:idle_timeout)

        case state.keepalive do
          {_, sent} when now - sent > timeout ->
            reject(state, "Keepalive timed out")

          # VMC-010c: the idle kick, checked with each keepalive (a hosted
          # session checks it on its own tick).
          _
          when idle > 0 and is_map_key(state, :last_action) and
                 now - state.last_action > idle * 60_000 ->
            reject(
              state,
              Valimc.Text.encode(Valimc.Text.translatable("multiplayer.disconnect.idling"))
            )

          nil ->
            id = System.unique_integer([:positive])
            send_packets(state, [Packets.packet("keep_alive", <<id::signed-64>>)])
            {:noreply, %{state | keepalive: {id, now}}}

          _ ->
            {:noreply, state}
        end
      else
        {:noreply, state}
      end
    end)
  end

  def info(
        {:player_tick, token},
        %{phase: :play, simulation_clock: %TickClock{} = clock} = state
      ) do
    guard(state, fn ->
      case TickClock.advance(clock, token, System.monotonic_time(:millisecond)) do
        {:ok, next, late, delay} ->
          schedule_player_tick(state, next, delay)
          Metrics.add(:player_ticks)
          if late > 0, do: Metrics.add(:player_tick_lateness_ms, late)

          player = %{
            state.player
            | living: Valimc.Living.tick(state.player.living, state.life_stage == :alive)
          }

          state = %{
            state
            | player: player,
              simulation_clock: next,
              simulation_due: true,
              air_policy: Valimc.Living.Air.policy(player.living.effects),
              # Base-step damage precedes expiry; retain only its relevant level
              # while bounded geometry samples coalesce to the latest admitted tick.
              environment_effects: Map.take(player.living.effects, [@resistance])
          }

          idle!(state)
          state = Vitals.tick_burning(state)
          state = Vitals.tick_effects(state)

          {:noreply,
           state
           |> Vitals.apply_void_damage()
           |> Vitals.apply_border_damage()
           |> ItemUse.tick_item_use()
           |> Vitals.tick_food()
           |> Vitals.reset_effect_fall()
           |> Mining.tick_mining()
           |> Menus.check_table_menu()
           |> Vitals.continue_life()
           |> Valimc.Player.Portals.tick()
           |> Valimc.Player.Travel.tick()
           |> Movement.sample_pose()}

        {:early, next, delay} ->
          schedule_player_tick(state, next, delay)
          {:noreply, %{state | simulation_clock: next}}

        :stale ->
          {:noreply, state}
      end
    end)
  end

  def info({:player_tick, _}, state), do: {:noreply, state}

  # The session's 50 ms work (its connection replicates the view on the same
  # timer): input and equipment, the pose, its own flags, and the items and
  # orbs it touches.
  def info(:publish_movement, %{phase: :play} = state) do
    guard(state, fn ->
      state =
        Movement.update_player_input(
          ItemUse.publish_equipment(state),
          Input.tick(state.player.input)
        )
        |> Movement.sample_pose()

      state =
        if state.player_flags_view != Valimc.Player.Packets.shared_flags(state.player) do
          send_packets(state, [Valimc.Player.Packets.player_flags(state.player)])
          %{state | player_flags_view: Valimc.Player.Packets.shared_flags(state.player)}
        else
          state
        end

      {touching, cache} = touching(state)
      state = Items.pickup(%{state | pickup_cache: cache}, touching)
      {:noreply, Items.collect_experience(state, touching)}
    end)
  end

  def info(:publish_movement, state), do: {:noreply, state}

  # The session entered play at its group (`Valimc.Session.Link`): a cursor
  # or grid left from a lost connection returns, and a death continues.
  def info(:entered, state),
    do:
      guard(state, fn ->
        state =
          case Inventory.disconnect(state.inventory) do
            {:ok, _, []} ->
              state

            {:ok, inventory, stacks} ->
              case Items.drop(state, inventory, stacks) do
                {:ok, state} -> CreativeInventory.resync_inventory(state)
                :error -> state
              end

            _ ->
              state
          end

        {:noreply, Vitals.continue_life(state)}
      end)

  # Play input from the connection (`Valimc.Session.Link`), applied in arrival
  # order between the group's ticks, as vanilla's server thread runs queued
  # packet tasks between ticks.
  def info({:input, id, payload}, state),
    do:
      guard(state, fn ->
        {:noreply, Valimc.Net.Serverbound.handle_packet(state, id, payload)}
      end)

  def info(:send_chunks, state),
    do:
      guard(state, fn ->
        {:noreply, Replication.stream_chunks(state)}
      end)

  # Region events of a dimension the player no longer is in are stale (VMC-026b);
  # those of its own dimension apply as they are.
  def info({:event, {:in_dimension, dimension, event}}, state) do
    if dimension == Valimc.World.Dimension.current(),
      do:
        guard(state, fn ->
          {:noreply, Events.session(state, event)}
        end),
      else: {:noreply, state}
  end

  # An untagged region event is the overworld's, stale for a player elsewhere.
  def info({:event, event}, state) do
    if is_tuple(event) and elem(event, 0) in @region_events and
         Valimc.World.Dimension.current() != :overworld,
       do: {:noreply, state},
       else:
         guard(state, fn ->
           {:noreply, Events.session(state, event)}
         end)
  end

  # Overload is signalled, not killed, so terminate/2 still saves and releases jobs.
  def info({:EXIT, _from, {:shutdown, :overloaded} = reason}, state),
    do: {:stop, reason, state}

  def info({:EXIT, _from, :normal}, state), do: {:noreply, state}

  def info({:EXIT, _from, reason}, state),
    do: {:stop, {:shutdown, {:linked_exit, reason}}, state}

  def info(message, state) do
    Logger.warning("Connection ignored unexpected message: #{inspect(message, limit: 8)}")
    {:noreply, state}
  end

  # Manual clocks (tests) tick only on explicit messages.
  defp schedule_player_tick(%{player_ticks: :manual}, _next, _delay), do: :ok

  defp schedule_player_tick(state, next, delay),
    do: Process.send_after(state.connection, {:player_tick, next.token}, delay)

  defp down(state, ref, pid) do
    {lids, closed} = ChestLidReplication.down(state.chest_lids, ref, pid)
    send_packets(state, Enum.map(closed, &Packets.chest_lid(&1, false)))
    state = %{state | chest_lids: lids}

    {:noreply, forget_pose_source(state, ref)}
  end

  # A group the pose was sampled from went down: the pose is sampled again.
  defp forget_pose_source(state, ref) do
    if Map.has_key?(state.pose_sources, ref) do
      %{
        state
        | pose_sources: Map.delete(state.pose_sources, ref),
          pose_generation: state.pose_generation + 1,
          pose_checked: nil
      }
    else
      state
    end
  end

  # VMC-010c: a player idle longer than `idle_timeout` minutes is kicked.
  defp idle!(state) do
    idle = Valimc.World.Settings.get(:idle_timeout)

    if idle > 0 and System.monotonic_time(:millisecond) - state.last_action > idle * 60_000,
      do:
        reject(
          state,
          Valimc.Text.encode(Valimc.Text.translatable("multiplayer.disconnect.idling"))
        )
  end

  # The items and orbs within reach of a pickup: the chunks around the player.
  defp touching(state) do
    %{x: x, z: z, dimension: dimension} = state.player
    {cx, cz} = Valimc.Data.Grid.chunk_key(x, z)
    chunks = for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}
    sections = MapSet.new(chunks, &Valimc.Data.Grid.section(dimension, &1))
    World.visible_entities(sections, chunks, state.pickup_cache)
  end
end
