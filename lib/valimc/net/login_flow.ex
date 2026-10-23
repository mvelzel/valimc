defmodule Valimc.Net.LoginFlow do
  @moduledoc "Login and world entry: finishing login, loading a saved player, starting the session and entering the world (VMC-069)."

  require Logger

  alias Valimc.Protocol.{
    Packets,
    Wire
  }

  alias Valimc.Session.Replication
  alias Valimc.Player.Movement
  alias Valimc.Player.ItemUse
  alias Valimc.Player.Vitals

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.Player.{GameMode, PlayerList, Food, Input, Kinetics, Life, Motion}

  alias Valimc.World.TickClock

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

  # `PlayerList.placeNewPlayer`'s duplicate check (VMC-010e): a session of the
  # same profile is kicked ("You logged in from another location") and the
  # login continues once it has left, as vanilla waits for it.
  defp join(player, attempts) do
    case PlayerList.join(player, Valimc.Admin.Login.bypasses_limit?(player)) do
      {:error, {:duplicate, old}} when attempts > 0 ->
        ref = Process.monitor(old)
        reason = Valimc.Text.translatable("multiplayer.disconnect.duplicate_login")
        Valimc.Player.PlayerList.deliver(old, {:kick, Valimc.Text.encode(reason)})

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
      pid: state.connection,
      name: name,
      uuid: if(profile, do: profile.uuid, else: Valimc.Data.UUID.offline(name)),
      properties: if(profile, do: profile.properties, else: []),
      entity_id: elem(Valimc.Entity.Ids.next(), 1),
      address: Valimc.Admin.Login.address(state.socket),
      x: Valimc.World.Spawn.pose().x,
      y: Valimc.World.Spawn.pose().y,
      z: Valimc.World.Spawn.pose().z,
      yaw: Valimc.World.Spawn.yaw(),
      pitch: Valimc.World.Spawn.pitch(),
      game_mode: mode,
      abilities: GameMode.abilities(mode, false),
      input: %Input{},
      motion: %Motion{},
      living: %Valimc.Living{},
      progression: %Valimc.Player.Progression{},
      food: %Food{},
      use_flags: 0,
      equipment: %{},
      last_death: nil,
      dimension: Valimc.World.Spawn.dimension(),
      death_dimension: :overworld,
      portal_cooldown: 0,
      seen_credits: false,
      respawn: nil,
      sleeping: nil,
      time_since_rest: 0,
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

    {storage, player, inventory} =
      case Valimc.Player.Storage.load(player.uuid) do
        {:ok, storage, nil} ->
          # A new player appears near the world spawn (VMC-027e).
          player = Map.merge(player, Valimc.World.PlayerSpawn.find())

          {storage, player,
           %{state.inventory | infinite_materials: player.abilities.infinite_materials}}

        {:ok, storage, snapshot} ->
          mode = snapshot.game_mode || player.game_mode
          abilities = GameMode.abilities(mode, snapshot.flying)
          {:ok, velocity} = Kinetics.restore_velocity(snapshot.velocity)

          {:ok, living} = Valimc.Living.restore(snapshot)

          inventory = %{
            snapshot.inventory
            | infinite_materials: abilities.infinite_materials
          }

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
              respawn: snapshot.respawn,
              # A sleeper saved in its bed gets up once it plays (VMC-040a).
              sleeping: snapshot.sleeping && %{bed: snapshot.sleeping, ticks: 0},
              time_since_rest: snapshot.time_since_rest,
              motion:
                Motion.flight(
                  %Motion{
                    fall_distance: snapshot.fall_distance,
                    velocity: velocity
                  },
                  abilities.flying
                ),
              progression: snapshot.progression,
              food: snapshot.food
          }

          player = if living.health.value <= 0, do: Life.dead(player), else: player

          unless Enum.all?(player.living.effects, fn {id, _} -> id in @live_effects end),
            do: reject(state, "Saved status effect is not implemented in this preview")

          {storage, player, inventory}

        {:error, reason} ->
          Logger.warning("Player state load failed: #{inspect(reason)}")
          reject(state, "Player save unavailable; please retry after storage is repaired")
      end

    # The connection works in its player's dimension from here on (VMC-026b).
    Valimc.World.Dimension.put(player.dimension)
    PlayerList.update(state.connection, player)

    # A dead player's drops (if a crash came before them) and a cursor or grid
    # left from a lost connection settle at its group once it plays (`:entered`).
    state = %{
      state
      | player: player,
        life_stage: life_stage(player, inventory),
        storage: storage,
        inventory: inventory
    }

    finish_login(state)
  end

  defp life_stage(player, inventory) do
    cond do
      player.living.health.value > 0 -> :alive
      Valimc.Menus.Inventory.contents(inventory) == [] and inventory.carried == nil -> :dead
      true -> :sealing_death
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

    # The one way into a level (`Valimc.Player.Level`): the world views first.
    {views, level} = Valimc.Player.Level.views()

    state = %{
      state
      | clock_version: views.clock_version,
        weather_view: views.weather,
        difficulty_view: views.difficulty,
        border_view: views.border
    }

    send_packets(state, [
      Valimc.Player.Packets.login(state.player),
      Valimc.Player.Packets.experience(state.player.progression.experience),
      Valimc.Blocks.CookingRecipeBook.packet(state.player.progression.recipes, true, false),
      level.border,
      level.clock,
      level.difficulty,
      Valimc.Player.Packets.abilities(state.player.abilities),
      Valimc.Player.Packets.health(state.player.living.health, state.player.food),
      Valimc.Player.Packets.spawn_position(),
      Valimc.Player.Packets.permission_level(
        state.player.entity_id,
        Valimc.Admin.Permissions.level(state.player)
      ),
      Valimc.Commands.packet(Valimc.Admin.Permissions.level(state.player)),
      Valimc.World.TickRate.state_packet(Valimc.World.TickRate.published()),
      Valimc.World.TickRate.step_packet(Valimc.World.TickRate.join_steps()),
      Valimc.Menus.Packets.inventory(state.inventory),
      Packets.cursor(state.inventory.carried),
      Packets.held_slot(state.inventory.selected),
      Packets.teleport(state.player, state.teleport),
      Packets.level_load_start(),
      Valimc.Player.Packets.player_info(state.player),
      Valimc.Living.Packets.interaction_attributes(state.player),
      Valimc.Living.Packets.armor_attributes(
        state.player.entity_id,
        Valimc.Living.Armor.attributes(Valimc.Living.Armor.equipment(state.inventory))
      ),
      Valimc.Player.Packets.player_environment(state.player),
      Valimc.Player.Packets.player_flags(state.player),
      Valimc.Player.Packets.player_pose(state.player),
      Valimc.Player.Packets.player_health(state.player),
      Valimc.Player.Packets.player_use(state.player),
      Packets.chat(
        "Welcome to ValiMC. Development preview (#{state.player.game_mode.current}); survival is being built. /help"
      )
    ])

    send_packets(state, level.weather ++ Valimc.Player.Level.effects(state.player))

    state =
      state
      |> Movement.publish_movement_speed()
      |> Movement.publish_absorption()
      |> Movement.publish_jump_boost()

    existing = PlayerList.ready(state.connection)
    state = state |> Valimc.Player.Presence.joined() |> Replication.update_view()

    state =
      Enum.reduce(existing, state, fn player, acc ->
        Valimc.Session.Events.view(acc, {:player_joined, player})
      end)

    clock = TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    ticks = Valimc.config(:player_ticks, state.player.uuid)
    if ticks == :timer, do: Process.send_after(state.connection, {:player_tick, clock.token}, 50)
    state = %{state | simulation_clock: clock, player_ticks: ticks}
    Process.send_after(state.connection, :publish_movement, 50)

    state =
      if state.player.living.health.value <= 0, do: Vitals.death_notice(state, false), else: state

    # In play the session runs at the group that owns the player's section.
    link = Valimc.Net.Link.host(state)
    Valimc.Net.Link.forward(link, :entered)
    link
  end
end
