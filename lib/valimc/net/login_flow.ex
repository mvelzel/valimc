defmodule Valimc.Net.LoginFlow do
  @moduledoc "Login and world entry: finishing login, reconciling a saved player, starting the session and entering the world (VMC-069)."

  require Logger

  alias Valimc.Protocol.{
    Packets,
    Wire
  }

  alias Valimc.Player.Transfers
  alias Valimc.Session.Replication
  alias Valimc.Player.Movement
  alias Valimc.Player.ItemUse
  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{GameMode, Players, PlayerFood, PlayerInput, PlayerKinetics, PlayerLife, PlayerMotion, PlayerStore, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.World.TickClock

  alias Valimc.World.{BorderReplication, WeatherReplication}
  @live_effects Valimc.Living.Effects.live()

  def finish_login(state) do
    threshold = Valimc.config(:compression_threshold)

    if threshold != nil,
      do:
        send_packets(state, [Packets.packet("login_compression", Wire.varint(threshold), :login)])

    state = %{state | threshold: threshold, step: :ack}

    send_packets(state, [
      Packets.packet(
        "login_finished",
        [
          state.player.uuid,
          Wire.string(state.player.name),
          Packets.properties(state.player.properties),
          :crypto.strong_rand_bytes(16)
        ],
        :login
      )
    ])

    state
  end

  def reconcile_login(state) do
    before = PlayerState.capture(state.player, state.inventory)
    {:ok, after_snapshot, key, records} = PlayerTransfers.plan_cleanup(before)

    if records == [] do
      state = %{state | inventory: Transfers.recovered_inventory(state, after_snapshot)}

      if state.player.living.health.value <= 0,
        do: Vitals.checkpoint_life(state, :death_done, after_snapshot),
        else: finish_login(state)
    else
      ref = make_ref()

      recovery = %{
        Transfers.new_recovery(:login, :prepare, nil)
        | ref: ref,
          plan: %{key: key, records: records, inventory: after_snapshot.inventory}
      }

      prepare =
        if state.player.living.health.value <= 0,
          do: &PlayerStore.prepare_death/7,
          else: &PlayerStore.prepare_transfer/7

      prepare.(
        state.player_store,
        state.store_fence,
        before,
        after_snapshot,
        key,
        records,
        ref
      )

      %{state | step: :recover, recovery: recovery}
    end
  end

  # `PlayerList.placeNewPlayer`'s duplicate check (VMC-010e): a session of the
  # same profile is kicked ("You logged in from another location") and the
  # login continues once it has left, as vanilla waits for it.
  defp join(player, attempts) do
    case Players.join(player, Valimc.Admin.Login.bypasses_limit?(player)) do
      {:error, {:duplicate, old}} when attempts > 0 ->
        ref = Process.monitor(old)
        reason = Valimc.Text.translatable("multiplayer.disconnect.duplicate_login")
        Valimc.Connection.deliver(old, {:kick, Valimc.Text.encode(reason)})

        receive do
          {:DOWN, ^ref, :process, ^old, _} -> :ok
        after
          10_000 -> Process.demonitor(ref, [:flush])
        end

        # The registry learns of the exit through its own monitor.
        Process.sleep(20)
        join(player, attempts - 1)

      {:error, {:duplicate, _}} ->
        {:error, "That name is already connected"}

      other ->
        other
    end
  end

  def start_player_login(state, name, profile \\ nil) do
    mode = GameMode.new(Valimc.World.Settings.get(:default_game_mode))

    player = %{
      pid: self(),
      name: name,
      uuid: if(profile, do: profile.uuid, else: Valimc.Connection.offline_uuid(name)),
      properties: if(profile, do: profile.properties, else: []),
      entity_id: elem(Valimc.World.EntityIds.next(), 1),
      address: Valimc.Admin.Login.address(state.socket),
      x: Valimc.World.Spawn.pose().x,
      y: Valimc.World.Spawn.pose().y,
      z: Valimc.World.Spawn.pose().z,
      yaw: Valimc.World.Spawn.yaw(),
      pitch: Valimc.World.Spawn.pitch(),
      game_mode: mode,
      abilities: GameMode.abilities(mode, false),
      input: %PlayerInput{},
      motion: %PlayerMotion{},
      living: %Valimc.Living{},
      progression: %Valimc.PlayerProgression{},
      food: %PlayerFood{},
      use_flags: 0,
      equipment: %{},
      last_death: nil,
      dimension: Valimc.World.Spawn.dimension(),
      death_dimension: :overworld,
      portal_cooldown: 0,
      seen_credits: false,
      pose: :standing,
      ready: false
    }

    # VMC-010a: the name cache learns every login before the list checks.
    Valimc.Admin.Lists.remember(player.uuid, name)

    if reason = Valimc.Admin.Login.refusal(player, Valimc.Admin.Login.address(state.socket)),
      do: reject(state, Valimc.Text.encode(reason))

    case join(player, 3) do
      :ok ->
        :ok

      {:error, :full} ->
        reject(
          state,
          Valimc.Text.encode(Valimc.Text.translatable("multiplayer.disconnect.server_full"))
        )

      {:error, reason} ->
        reject(state, reason)
    end

    {store, fence, player, inventory, pending} =
      case PlayerStore.open(player.uuid) do
        {:ok, pid, nil, fence} ->
          # A new player appears near the world spawn (VMC-027e).
          player = Map.merge(player, Valimc.World.PlayerSpawn.find())

          {pid, fence, player,
           %{state.inventory | infinite_materials: player.abilities.infinite_materials}, nil}

        {:ok, pid, snapshot, fence} ->
          mode = snapshot.game_mode || player.game_mode
          abilities = GameMode.abilities(mode, snapshot.flying)
          {:ok, velocity} = PlayerKinetics.restore_velocity(snapshot.velocity)

          {:ok, living} = Valimc.Living.restore(snapshot)

          inventory = %{
            snapshot.inventory
            | infinite_materials: abilities.infinite_materials
          }

          pending =
            if snapshot.outbox != nil, do: Map.take(snapshot, [:outbox, :transfer_sequence])

          player = %{
            Map.merge(player, snapshot.pose)
            | game_mode: mode,
              abilities: abilities,
              living: living,
              last_death: snapshot.last_death,
              dimension: snapshot.dimension,
              death_dimension: snapshot.death_dimension,
              portal_cooldown: snapshot.portal_cooldown,
              seen_credits: snapshot.seen_credits,
              motion:
                PlayerMotion.flight(
                  %PlayerMotion{
                    fall_distance: snapshot.fall_distance,
                    velocity: velocity
                  },
                  abilities.flying
                ),
              progression: snapshot.progression,
              food: snapshot.food
          }

          player = if living.health.value <= 0, do: PlayerLife.dead(player), else: player

          unless Enum.all?(player.living.effects, fn {id, _} -> id in @live_effects end),
            do: reject(state, "Saved status effect is not implemented in this preview")

          {pid, fence, player, inventory, pending}

        {:error, reason} ->
          Logger.warning("Player state load failed: #{inspect(reason)}")
          reject(state, "Player save unavailable; please retry after storage is repaired")
      end

    # The connection works in its player's dimension from here on (VMC-026b).
    Valimc.Dimension.put(player.dimension)
    Players.update(self(), player)

    state = %{
      state
      | player: player,
        life_stage: if(player.living.health.value <= 0, do: :sealing_death, else: :alive),
        player_store: store,
        store_fence: fence,
        inventory: inventory,
        store_monitor: Process.monitor(store)
    }

    if pending do
      recovery = Transfers.new_recovery(:login, :delivery, pending)

      Transfers.deliver_recovery(%{state | step: :recover, recovery: recovery})
    else
      reconcile_login(state)
    end
  end

  def enter_world(state) do
    state = ItemUse.publish_equipment(state)

    state = %{
      state
      | phase: :play,
        step: nil,
        player: %{state.player | ready: true},
        login_velocity_pending: state.player.motion.velocity != {0.0, 0.0, 0.0}
    }

    {clock_version, clock_packet} = Valimc.World.Clock.initial()

    {weather_view, weather_packets} =
      WeatherReplication.reconcile(nil, Valimc.World.Clock.weather())

    {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()
    border = Valimc.World.Clock.border()

    state = %{
      state
      | clock_version: clock_version,
        weather_view: weather_view,
        difficulty_view: difficulty,
        border_view: border
    }

    send_packets(state, [
      Packets.login(state.player),
      Packets.experience(state.player.progression.experience),
      Valimc.CookingRecipeBook.packet(state.player.progression.recipes, true, false),
      BorderReplication.initialize(border),
      clock_packet,
      difficulty_packet,
      Packets.abilities(state.player.abilities),
      Packets.health(state.player.living.health, state.player.food),
      Packets.spawn_position(),
      Packets.permission_level(
        state.player.entity_id,
        Valimc.Permissions.level(state.player)
      ),
      Packets.commands(Valimc.Permissions.level(state.player)),
      Valimc.World.TickRate.state_packet(Valimc.World.TickRate.published()),
      Valimc.World.TickRate.step_packet(Valimc.World.TickRate.join_steps()),
      Packets.inventory(state.inventory),
      Packets.cursor(state.inventory.carried),
      Packets.held_slot(state.inventory.selected),
      Packets.teleport(state.player, state.teleport),
      Packets.level_load_start(),
      Packets.player_info(state.player),
      Packets.interaction_attributes(state.player),
      Packets.armor_attributes(
        state.player.entity_id,
        Valimc.Living.Armor.attributes(Valimc.Living.Armor.equipment(state.inventory))
      ),
      Packets.player_environment(state.player),
      Packets.player_flags(state.player),
      Packets.player_pose(state.player),
      Packets.player_health(state.player),
      Packets.player_use(state.player),
      Packets.chat(
        "Welcome to ValiMC. Development preview (#{state.player.game_mode.current}); survival is being built. /help"
      )
    ])

    send_packets(state, weather_packets)

    send_packets(
      state,
      Enum.map(state.player.living.effects, fn {id, [rung | _]} ->
        Packets.update_effect(state.player.entity_id, id, rung, false)
      end)
    )

    state =
      state
      |> Movement.publish_movement_speed()
      |> Movement.publish_absorption()
      |> Movement.publish_jump_boost()

    existing = Players.ready(self())
    state = state |> Valimc.Session.Presence.joined() |> Replication.update_view()

    state =
      Enum.reduce(existing, state, fn player, acc ->
        Valimc.Session.Events.event(acc, {:player_joined, player})
      end)

    clock = TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    ticks = Valimc.config(:player_ticks, state.player.uuid)
    if ticks == :timer, do: Process.send_after(self(), {:player_tick, clock.token}, 50)
    state = %{state | simulation_clock: clock, player_ticks: ticks}
    Process.send_after(self(), :publish_movement, 50)
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))
    if state.player.living.health.value <= 0, do: Vitals.death_notice(state, false), else: state
  end
end
