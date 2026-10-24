defmodule Valimc.Session.Messages do
  @moduledoc """
  A session's message router (VMC-069): its jobs' outcomes, ticks, play
  input and deliveries. In play the session's group runs it on the session
  (`Valimc.Player.Host`, whose callbacks it implements); the connection's
  own messages (socket data, login jobs, keepalives, the chunk stream) are
  `Valimc.Net.Messages`', which runs before play on the whole state and
  hands the rest here. `guard/2` is every session's exception boundary.
  """
  @behaviour Valimc.Player.Host

  alias Valimc.Data.Grid
  require Logger

  alias Valimc.Data.EffectTypes

  alias Valimc.Session.Events
  alias Valimc.Player.Jobs
  alias Valimc.Player.{CreativeInventory, Items, ItemUse, Menus, Mining, Movement, Vitals}

  import Valimc.Protocol.Codec, only: [send_packets: 2, reject: 2]

  alias Valimc.Menus.Inventory
  alias Valimc.Data.Metrics
  alias Valimc.Player.Input
  alias Valimc.World
  alias Valimc.World.TickClock

  @resistance EffectTypes.id("resistance")
  # Events region owners publish to their visibility topics (`Valimc.World.publish/2`).
  @region_events [
    :block,
    :block_batch,
    :level_events,
    :sound,
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

  @doc """
  Route `message`: a session job's outcome (`Valimc.Player.Jobs`), else
  `fallback` (the session's own messages, `info/2`; the connection's router
  before play, `Valimc.Net.Messages`).
  """
  @impl Valimc.Player.Host
  def dispatch(message, state, fallback \\ &info/2)

  def dispatch(message, %{jobs: %Jobs{}} = state, fallback) do
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
        fallback.(message, state)
    end
  end

  def dispatch(message, state, fallback), do: fallback.(message, state)

  @doc """
  Whether a process-bound `message` (a task reply, a DOWN, a job timer) is
  this session's: its group hands it the ones it claims.
  """
  @impl Valimc.Player.Host
  def claims?(session, {:job_timeout, kind, ref}),
    do: match?(%{ref: ^ref}, Jobs.get(session.jobs, kind))

  def claims?(session, {:DOWN, ref, :process, _, _}), do: owns_ref?(session, ref)
  def claims?(session, {ref, _}) when is_reference(ref), do: owns_ref?(session, ref)
  def claims?(_session, _message), do: false

  defp owns_ref?(session, ref) do
    Map.has_key?(session.jobs.refs, ref) or Map.has_key?(session.pose_sources, ref)
  end

  @doc "A session moves to another group only without a job: no reply follows it."
  @impl Valimc.Player.Host
  def movable?(session), do: session.jobs.active == %{}

  @doc "A session that moved here watches the groups its pose was sampled from."
  @impl Valimc.Player.Host
  def adopted(%{pose_sources: sources} = session) when sources == %{}, do: session

  def adopted(session),
    do:
      Valimc.Player.Movement.monitor_pose_sources(
        %{session | pose_sources: %{}},
        Map.values(session.pose_sources)
      )

  @doc """
  A session ends: its view and jobs are released and the cursor and grid
  drop (vanilla's `removed` of the open menu for a player who disconnected).
  Returns the state its last frame saves (`Valimc.Player.Host`).
  """
  @impl Valimc.Player.Host
  def terminate(state) do
    # A sleeper leaving frees its bed (`ServerPlayer.disconnect`).
    state =
      if state.phase == :play,
        do: Valimc.Player.Sleep.stop(state, true, teleport: false),
        else: state

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

  # `/save-all` (VMC-010b): the player's file as soon as its frames are durable.
  def info(:save_player_now, %{storage: %Valimc.Player.Storage{} = storage} = state),
    do: {:noreply, %{state | storage: Valimc.Player.Storage.request_checkpoint(storage)}}

  def info(:save_player_now, state), do: {:noreply, state}

  # An entity's melee hit on this player (VMC-037n, `Player.Hurt`).
  def info({:hurt, hit}, %{phase: :play} = state),
    do: guard(state, fn -> {:noreply, elem(Valimc.Player.Hurt.hurt(state, hit), 1)} end)

  def info({:boss_packet, packet}, %{phase: :play} = state) do
    Valimc.Protocol.Codec.send_packets(state, [packet])
    {:noreply, state}
  end

  def info({:dragon_contact, hit, push, wing}, %{phase: :play} = state),
    do:
      guard(state, fn -> {:noreply, Valimc.Player.Hurt.dragon_contact(state, hit, push, wing)} end)

  # What the player's projectiles and others' bring back (VMC-037o).
  def info({:ender_pearl, position}, %{phase: :play} = state),
    do: guard(state, fn -> {:noreply, Valimc.Player.Projectiles.pearl(state, position)} end)

  def info({:splash, actions, template}, %{phase: :play} = state),
    do:
      guard(state, fn ->
        {:noreply, Valimc.Player.Projectiles.splash(state, actions, template)}
      end)

  def info(:arrow_hit_player, %{phase: :play} = state),
    do: {:noreply, Valimc.Player.Projectiles.arrow_hit(state)}

  # Cancelling geometry retires its reference; a result already in this mailbox
  # must never become a new player input or crash a healthy connection.
  def info({ref, _}, state) when is_reference(ref), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, state), do: {:noreply, forget_pose_source(state, ref)}

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
           |> Valimc.Player.Attack.tick()
           |> Vitals.tick_food()
           |> Vitals.reset_effect_fall()
           |> Mining.tick_mining()
           |> Menus.check_table_menu()
           |> Valimc.Player.Sleep.tick()
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
      state = Valimc.Player.Projectiles.pickup(state, touching)
      {:noreply, Items.collect_experience(state, touching)}
    end)
  end

  def info(:publish_movement, state), do: {:noreply, state}

  # The session entered play at its group (`Valimc.Net.Link`): a cursor
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

        # A player saved asleep gets up (`readAdditionalSaveData`, VMC-040a).
        state = Valimc.Player.Sleep.stop(state, true)
        {:noreply, Vitals.continue_life(state)}
      end)

  # Play input from the connection (`Valimc.Net.Link`), applied in arrival
  # order between the group's ticks, as vanilla's server thread runs queued
  # packet tasks between ticks.
  def info({:input, id, payload}, state),
    do:
      guard(state, fn ->
        {:noreply, Valimc.Session.Play.handle(state, id, payload)}
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

  # Enough players slept through the night (VMC-040a): the environment
  # owner woke this one.
  def info({:sleep, :woken}, %{phase: :play} = state),
    do:
      guard(state, fn ->
        {:noreply, Valimc.Player.Sleep.stop(state, false, notify: false)}
      end)

  # An explosion near the player (VMC-050a), from its group.
  def info({:explosion, explosion, count}, state),
    do: {:noreply, Valimc.Player.Explosions.hit(state, explosion, count)}

  # Moving blocks' pushes near the player (VMC-048b), from its group.
  def info({:piston_pushes, pushes}, state),
    do: {:noreply, Valimc.Player.Pistons.push(state, pushes)}

  def info({:shulker_push, area, delta}, state),
    do: {:noreply, Valimc.Player.Displacement.push(state, area, delta)}

  # An anvil landing (VMC-050a2), from its group.
  def info({:falling_block, box, amount}, state),
    do: {:noreply, Valimc.Player.Explosions.falling_block(state, box, amount)}

  def info(message, state) do
    Logger.warning("Connection ignored unexpected message: #{inspect(message, limit: 8)}")
    {:noreply, state}
  end

  # Manual clocks (tests) tick only on explicit messages.
  defp schedule_player_tick(%{player_ticks: :manual}, _next, _delay), do: :ok

  defp schedule_player_tick(state, next, delay),
    do: Process.send_after(state.connection, {:player_tick, next.token}, delay)

  @doc "A group the pose was sampled from went down: the pose is sampled again."
  def forget_pose_source(state, ref) do
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
    {cx, cz} = Grid.chunk_key(x, z)
    chunks = for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}
    sections = MapSet.new(chunks, &Grid.section(dimension, &1))
    World.visible_entities(sections, chunks, state.pickup_cache)
  end
end
