defmodule Valimc.Net.LoginFlow do
  @moduledoc "Login and world entry: finishing login, reconciling a saved player, starting the session and entering the world (VMC-069)."

  require Logger

  alias Valimc.Protocol.{
    EffectTypes,
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

  alias Valimc.{
    GameMode,
    Players,
    PlayerAbsorption,
    PlayerEnvironment,
    PlayerFood,
    PlayerHealth,
    PlayerInput,
    PlayerKinetics,
    PlayerLife,
    PlayerMotion,
    PlayerSnapshot,
    PlayerStore,
    PlayerTransfers
  }

  alias Valimc.World.TickClock

  alias Valimc.World.{BorderReplication, WeatherReplication}
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
    before = PlayerSnapshot.capture(state.player, state.inventory)
    {:ok, after_snapshot, key, records} = PlayerTransfers.plan_cleanup(before)

    if records == [] do
      state = %{state | inventory: Transfers.recovered_inventory(state, after_snapshot)}

      if state.player.health.value <= 0,
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
        if state.player.health.value <= 0,
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

  def start_player_login(state, name, profile \\ nil) do
    mode = GameMode.new(Valimc.config(:default_game_mode))

    player = %{
      pid: self(),
      name: name,
      uuid: if(profile, do: profile.uuid, else: Valimc.Connection.offline_uuid(name)),
      properties: if(profile, do: profile.properties, else: []),
      entity_id: System.unique_integer([:positive]),
      x: Valimc.World.Spawn.pose().x,
      y: Valimc.World.Spawn.pose().y,
      z: Valimc.World.Spawn.pose().z,
      yaw: Valimc.World.Spawn.yaw(),
      pitch: 0.0,
      game_mode: mode,
      abilities: GameMode.abilities(mode, false),
      input: %PlayerInput{},
      motion: %PlayerMotion{},
      environment: %PlayerEnvironment{},
      air_supply: Valimc.PlayerAir.maximum(),
      fire_ticks: 0,
      effects: %{},
      absorption: 0.0,
      progression: %Valimc.PlayerProgression{},
      food: %PlayerFood{},
      use_flags: 0,
      equipment: %{},
      health: %PlayerHealth{},
      last_death: nil,
      pose: :standing,
      ready: false
    }

    case Players.join(player) do
      :ok -> :ok
      {:error, reason} -> reject(state, reason)
    end

    {store, fence, player, inventory, pending} =
      case PlayerStore.open(player.uuid) do
        {:ok, pid, nil, fence} ->
          {pid, fence, player,
           %{state.inventory | infinite_materials: player.abilities.infinite_materials}, nil}

        {:ok, pid, snapshot, fence} ->
          mode = Map.get(snapshot, :game_mode, player.game_mode)
          abilities = GameMode.abilities(mode, Map.get(snapshot, :flying, false))

          {:ok, velocity} =
            PlayerKinetics.restore_velocity(Map.get(snapshot, :velocity, {0.0, 0.0, 0.0}))

          {:ok, health} = PlayerHealth.restore(Map.get(snapshot, :health))

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
              health: health,
              last_death: Map.get(snapshot, :last_death),
              motion:
                PlayerMotion.flight(
                  %PlayerMotion{
                    fall_distance: Map.get(snapshot, :fall_distance, 0.0),
                    velocity: velocity
                  },
                  abilities.flying
                ),
              environment: %PlayerEnvironment{frozen_ticks: Map.get(snapshot, :frozen_ticks, 0)},
              air_supply: Map.get(snapshot, :air_supply, Valimc.PlayerAir.maximum()),
              fire_ticks: Map.get(snapshot, :fire_ticks, 0),
              effects: Map.get(snapshot, :effects, %{}),
              absorption: Map.get(snapshot, :absorption, 0.0),
              progression: Map.get(snapshot, :progression, %Valimc.PlayerProgression{}),
              food: Map.get(snapshot, :food, %PlayerFood{})
          }

          player = PlayerAbsorption.reconcile(player)
          player = if health.value <= 0, do: PlayerLife.dead(player), else: player

          unless Enum.all?(player.effects, fn {id, _} -> id in @live_effects end),
            do: reject(state, "Saved status effect is not implemented in this preview")

          {pid, fence, player, inventory, pending}

        {:error, reason} ->
          Logger.warning("Player state load failed: #{inspect(reason)}")
          reject(state, "Player save unavailable; please retry after storage is repaired")
      end

    Players.update(self(), player)

    state = %{
      state
      | player: player,
        life_stage: if(player.health.value <= 0, do: :sealing_death, else: :alive),
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
      Packets.health(state.player.health, state.player.food),
      Packets.spawn_position(),
      Packets.permission_level(
        state.player.entity_id,
        Valimc.Permissions.level(state.player.name)
      ),
      Packets.commands(Valimc.Permissions.level(state.player.name)),
      Packets.inventory(state.inventory),
      Packets.cursor(state.inventory.carried),
      Packets.held_slot(state.inventory.selected),
      Packets.teleport(state.player, state.teleport),
      Packets.level_load_start(),
      Packets.player_info(state.player),
      Packets.interaction_attributes(state.player),
      Packets.armor_attributes(state.player, Valimc.PlayerArmor.attributes(state.inventory)),
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
      Enum.map(state.player.effects, fn {id, [rung | _]} ->
        Packets.update_effect(state.player.entity_id, id, rung, false)
      end)
    )

    state =
      state
      |> Movement.publish_movement_speed()
      |> Movement.publish_absorption()
      |> Movement.publish_jump_boost()

    existing = Players.ready(self())
    state = Replication.update_view(state)

    state =
      Enum.reduce(existing, state, fn player, acc ->
        Valimc.Session.Events.event(acc, {:player_joined, player})
      end)

    clock = TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    Process.send_after(self(), {:player_tick, clock.token}, 50)
    state = %{state | simulation_clock: clock}
    Process.send_after(self(), :publish_movement, 50)
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))
    if state.player.health.value <= 0, do: Vitals.death_notice(state, false), else: state
  end
end
