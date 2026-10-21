defmodule Valimc.Player.Vitals do
  @moduledoc "Player vitals inside the connection: food, health, damage, death and respawn, burning, effects, environment and air (VMC-069)."

  alias Valimc.Protocol.{
    ClientTick,
    EffectTypes,
    Packets
  }

  import Valimc.Net.Codec,
    only: [send_packets: 2]

  alias Valimc.{
    CreativeInput,
    Inventory,
    PeriodicEffect,
    Players,
    PlayerAbsorption,
    PlayerEnvironment,
    PlayerEffects,
    PlayerFood,
    PlayerHealth,
    PlayerLife,
    PlayerSnapshot,
    PlayerStore,
    PlayerStatusImmunity,
    PlayerTransfers,
    World
  }

  alias Valimc.World.{BorderReplication, EntityReplication, WeatherReplication}
  import Bitwise
  @hunger EffectTypes.id("hunger")
  @absorption EffectTypes.id("absorption")
  @periodic_effects Enum.sort(Enum.map(~w(regeneration hunger poison wither), &EffectTypes.id/1))

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def apply_landing(state, nil), do: state

  def apply_landing(state, call) do
    {:ok, jump} = Valimc.PlayerJumpBoost.derive(state.player.effects)

    {:ok, amount} =
      Valimc.Physics.FallDamage.calculate(
        call.distance,
        call.multiplier,
        %Valimc.Physics.FallDamage{safe_distance: jump.safe_distance}
      )

    if amount > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
      {_, state} = apply_damage(state, selected, call.source)
      state
    else
      state
    end
  end

  def apply_void_damage(%{life_stage: :alive} = state) do
    {min_y, _height} = Valimc.Dimension.bounds()
    amount = Valimc.PlayerVoid.damage(state.player.y, min_y)

    if amount > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
      {_, state} = apply_damage(state, selected, :out_of_world)
      state
    else
      state
    end
  end

  def apply_void_damage(state), do: state

  @doc """
  Damage outside the world border (VMC-027b), after the below-world check as
  in `LivingEntity.baseTick`. Suffocation inside blocks, which vanilla checks
  first, is not modelled yet.
  """
  def apply_border_damage(%{life_stage: :alive} = state) do
    amount =
      Valimc.World.Border.damage(
        Valimc.World.Clock.border_physics(),
        state.player.x,
        state.player.z
      )

    if amount > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
      {_, state} = apply_damage(state, selected, :outside_border)
      state
    else
      state
    end
  end

  def apply_border_damage(state), do: state

  def apply_movement_exhaustion(%{player: %{abilities: %{invulnerable: true}}} = state, _),
    do: state

  def apply_movement_exhaustion(state, %{jump: jump, travel: travel})
      when jump == 0 and travel == 0,
      do: state

  def apply_movement_exhaustion(state, %{jump: jump, travel: travel}) do
    food = state.player.food |> PlayerFood.exhaust(jump) |> PlayerFood.exhaust(travel)
    player = %{state.player | food: food}
    if food != state.player.food, do: Players.update(self(), player)
    %{state | player: player}
  end

  def tick_food(%{life_stage: :alive} = state) do
    phase = rem(state.simulation_clock.tick - state.food_tick_origin, 20)

    if PlayerFood.idle?(state.player.food, state.player.health, phase),
      do: state,
      else: advance_food(state, phase)
  end

  def tick_food(state), do: state

  def advance_food(state, phase) do
    {difficulty, regeneration} = World.Clock.survival()
    before = state.player

    {food, peaceful_heal} =
      PlayerFood.peaceful(before.food, before.health, difficulty, regeneration, phase)

    health = heal(before.health, peaceful_heal)
    {food, effect} = PlayerFood.tick(food, health, difficulty, regeneration)
    health = heal(health, effect.heal)

    state =
      if before.food != food or before.health != health do
        player = %{before | food: food, health: health}
        Players.update(self(), player)
        %{state | player: player}
      else
        state
      end

    # Native replication observes health, food and whether saturation crossed zero.
    if before.health.value != health.value or before.food.level != food.level or
         before.food.saturation == 0 != (food.saturation == 0),
       do: send_packets(state, [Packets.health(health, food)])

    if before.health.value != health.value do
      packet = Packets.player_health(state.player)
      send_packets(state, [packet])
      Valimc.Player.Movement.broadcast_player_packet(state, packet)
    end

    if effect.damage > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(health, effect.damage)
      {_, state} = apply_damage(state, selected, :starve)
      state
    else
      state
    end
  end

  def heal(health, amount) do
    if health.value > 0 and amount > 0 do
      {:ok, next} = PlayerHealth.set(health, health.value + amount)
      next
    else
      health
    end
  end

  def apply_damage(state, selected, source, effects \\ nil) do
    result =
      if state.life_stage != :alive,
        do: :ignored,
        else:
          Valimc.PlayerDamage.resolve(
            state.player,
            state.inventory,
            selected,
            source,
            effects || state.player.effects,
            inventory_pending(state)
          )

    case result do
      reason when reason in [:ignored, :immune, :deferred] ->
        {reason, state}

      {:ok, %{player: player, inventory: inventory, broken: broken}} ->
        health = player.health

        state =
          if inventory == state.inventory do
            %{state | player: player}
          else
            %{state | player: player, inventory: inventory}
            |> Valimc.Player.CreativeInventory.resync_inventory()
            |> Valimc.Player.ItemUse.publish_equipment()
          end

        for {slot, _stack} <- broken do
          packet = Packets.armor_break(player.entity_id, slot)
          send_packets(state, [packet])
          Valimc.Player.Movement.broadcast_player_packet(state, packet)
        end

        state =
          if health.value <= 0 do
            state =
              state
              |> Valimc.Player.Movement.cancel_pose_job()
              |> Valimc.Player.Movement.cancel_motion_job()
              |> Valimc.Player.ItemUse.stop_item_use()
              |> Valimc.Player.Mining.cancel_mining()

            dead_state(state)
          else
            state
          end

        state =
          if health.value <= 0, do: Valimc.Player.Menus.begin_table_close(state), else: state

        Players.update(self(), state.player)

        if selected.notify do
          packet = Packets.damage_event(state.player.entity_id, source)
          send_packets(state, [packet])
          Valimc.Player.Movement.broadcast_player_packet(state, packet)
        end

        send_packets(state, [
          Packets.health(state.player.health, state.player.food),
          Packets.player_health(state.player)
        ])

        state = Valimc.Player.Movement.publish_absorption(state)
        state = if health.value <= 0, do: death_notice(state, true, source), else: state
        send(self(), :drain)
        {if(health.value <= 0, do: :dead, else: :hurt), continue_life(state)}
    end
  end

  def dead_state(state) do
    %{
      state
      | player: PlayerLife.die(state.player),
        motion_pending: nil,
        motion_window: nil,
        pose_checked: nil,
        pose_generation: state.pose_generation + 1,
        life_stage: :sealing_death,
        fire_damage_due: false,
        fire_contacts_active: false,
        creative_input: CreativeInput.clear(state.creative_input)
    }
  end

  def death_notice(state, announce, source \\ :fall) do
    message =
      Valimc.PlayerDeathMessage.component(
        state.player.name,
        if(announce, do: source, else: :generic)
      )

    send_packets(state, [
      Packets.player_pose(state.player),
      Packets.death(state.player.entity_id, message),
      Packets.death_animation(state.player.entity_id)
    ])

    Valimc.Player.Movement.broadcast_player_packet(
      state,
      Packets.death_animation(state.player.entity_id)
    )

    if announce, do: Players.broadcast({:chat, message})
    state
  end

  def checkpoint_life(state, kind, snapshot, player \\ nil) do
    ref = make_ref()
    PlayerStore.checkpoint(state.player_store, state.store_fence, snapshot, ref)
    Process.send_after(self(), {:save_deadline, ref}, 5000)

    %{
      state
      | save_ref: ref,
        life_save: %{kind: kind, ref: ref, snapshot: snapshot, player: player}
    }
  end

  def continue_life(%{save_ref: ref} = state) when ref != nil, do: state
  def continue_life(%{recovery: recovery} = state) when recovery != nil, do: state

  def continue_life(%{life_stage: :sealing_death, phase: :play} = state),
    do: checkpoint_life(state, :death_mark, PlayerSnapshot.capture(state.player, state.inventory))

  def continue_life(%{life_stage: :dropping, phase: :play} = state) do
    before = PlayerSnapshot.capture(state.player, state.inventory)
    {:ok, after_snapshot, key, records} = PlayerTransfers.plan_death(before)

    if records == [] do
      checkpoint_life(state, :death_done, after_snapshot)
    else
      ref = make_ref()

      recovery = %{
        Valimc.Player.Transfers.new_recovery(:death, :prepare, nil)
        | ref: ref,
          plan: %{key: key, records: records, inventory: after_snapshot.inventory}
      }

      PlayerStore.prepare_death(
        state.player_store,
        state.store_fence,
        before,
        after_snapshot,
        key,
        records,
        ref
      )

      %{state | recovery: recovery}
    end
  end

  def continue_life(%{life_stage: :dead, respawn_requested: true} = state) do
    spawn = Valimc.Dimension.within(:overworld, &Valimc.World.PlayerSpawn.find/0)
    player = PlayerLife.respawn(state.player, spawn)
    snapshot = PlayerSnapshot.capture(player, Inventory.new(player.abilities.infinite_materials))
    checkpoint_life(%{state | life_stage: :respawning}, :respawn, snapshot, player)
  end

  def continue_life(state), do: state

  def finish_respawn(state, player) do
    old_entities = Enum.map(state.peers, fn {_, view} -> Packets.remove_entity(view) end)

    old_items = Map.keys(state.entity_replication.tracked)

    old_items =
      if old_items == [], do: [], else: [Valimc.Protocol.EntityPackets.remove(old_items)]

    send_packets(state, Enum.map(state.chunks, &Packets.unload/1) ++ old_entities ++ old_items)

    # Post effects (`/posteffect`) do not survive a respawn, as in vanilla.
    if Map.get(state.player, :post_effects, []) != [],
      do: send_packets(state, [Valimc.Commands.PostEffects.packet([])])

    player = Map.put(player, :post_effects, [])
    # A death in another dimension respawns in the overworld (VMC-026b).
    state = Valimc.Player.Travel.leave(state, player)
    {clock_version, clock_packet} = Valimc.World.Clock.initial()
    {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()

    {weather_view, weather_packets} =
      WeatherReplication.reconcile(nil, Valimc.World.Clock.weather())

    border = Valimc.World.Clock.border()
    inventory = Inventory.new(player.abilities.infinite_materials)

    state = %{
      state
      | player: player,
        inventory: inventory,
        life_stage: :alive,
        air_policy: :none,
        environment_effects: %{},
        movement_speed_view: nil,
        absorption_view: nil,
        jump_boost_view: nil,
        fire_damage_due: false,
        fire_contacts_active: false,
        active_use: nil,
        respawn_requested: false,
        food_tick_origin: state.simulation_clock.tick,
        client_tick: %ClientTick{},
        view: nil,
        chunks: MapSet.new(),
        pending: [],
        peers: %{},
        entity_replication: EntityReplication.new(),
        entity_cache: %{},
        clock_version: clock_version,
        difficulty_view: difficulty,
        weather_view: weather_view,
        border_view: border
    }

    send_packets(
      state,
      [
        Packets.respawn(player, player.last_death),
        BorderReplication.initialize(border),
        Packets.level_load_start(),
        clock_packet,
        difficulty_packet,
        Packets.abilities(player.abilities),
        Packets.health(player.health, player.food),
        Packets.player_health(player),
        Packets.player_use(player),
        Packets.player_pose(player),
        Packets.player_environment(player),
        Packets.player_flags(player),
        Packets.spawn_position(),
        Packets.interaction_attributes(player),
        Packets.armor_attributes(player, Valimc.PlayerArmor.attributes(inventory)),
        Packets.inventory(inventory),
        Packets.cursor(nil),
        Packets.held_slot(0)
      ] ++ weather_packets
    )

    state =
      state
      |> Valimc.Player.Movement.publish_movement_speed()
      |> Valimc.Player.Movement.publish_absorption()
      |> Valimc.Player.Movement.publish_jump_boost()
      |> Valimc.Player.Movement.relocate(player)

    for pid <- Players.nearby(state.regions),
        pid != self(),
        do: Valimc.Connection.deliver(pid, {:player_respawned, self(), player.entity_id})

    %{state | life_save: nil}
  end

  def tick_burning(%{life_stage: stage} = state) when stage != :alive,
    do: %{state | fire_damage_due: false}

  def tick_burning(state) do
    {:ok, burning} =
      Valimc.PlayerBurning.tick(
        state.player.fire_ticks,
        false,
        false,
        state.player.abilities.invulnerable
      )

    player = %{state.player | fire_ticks: burning.ticks}
    burning_now = player.fire_ticks > 0
    burning_before = state.player.fire_ticks > 0
    if burning_now != burning_before, do: Players.update(self(), player)

    %{
      state
      | player: player,
        pose_checked: if(burning_before and not burning_now, do: nil, else: state.pose_checked),
        fire_damage_due:
          burning.ticks > 0 and
            not PlayerStatusImmunity.immune?(state.player.effects, :on_fire) and
            (state.fire_damage_due or burning.damage > 0)
    }
  end

  def tick_effects(%{life_stage: :alive, player: %{effects: effects}} = state)
      when map_size(effects) > 0 do
    before_level = Valimc.Player.Movement.absorption_level(effects)
    depleted = Map.has_key?(effects, @absorption) and state.player.absorption == 0
    effects = if depleted, do: Map.delete(effects, @absorption), else: effects
    {:ok, after_effects, events} = PlayerEffects.tick(effects)
    events = if depleted, do: [{:remove, @absorption} | events], else: events
    # Requests read pre-decrement heads. Publish the final duration map to this
    # owner before health application can seal a durable death snapshot.
    state = %{state | player: %{state.player | effects: after_effects}}
    unsigned_age = band(state.simulation_clock.tick, 0xFFFFFFFF)
    age = if unsigned_age >= 2_147_483_648, do: unsigned_age - 4_294_967_296, else: unsigned_age

    next =
      Enum.reduce_while(@periodic_effects, state, fn id, current ->
        cond do
          current.life_stage != :alive ->
            {:halt, current}

          not Map.has_key?(effects, id) ->
            {:cont, current}

          true ->
            {:ok, action} =
              if id == @hunger,
                do: Valimc.HungerEffect.request(effects[id]),
                else: PeriodicEffect.request(id, effects[id], age, current.player.health)

            {:cont, apply_effect_action(current, action)}
        end
      end)

    {next, events} =
      if next.life_stage == :alive and next.player.absorption == 0 and
           Map.has_key?(next.player.effects, @absorption) do
        player = %{next.player | effects: Map.delete(next.player.effects, @absorption)}
        events = Enum.reject(events, fn event -> elem(event, 1) == @absorption end)
        {%{next | player: player}, events ++ [{:remove, @absorption}]}
      else
        {next, events}
      end

    # Damage requests above spend the pre-expiry pool; promotion/removal then
    # clamps it to the final maximum without starting another dose.
    player =
      if next.life_stage == :alive and
           before_level != Valimc.Player.Movement.absorption_level(next.player.effects),
         do: PlayerAbsorption.reconcile(next.player),
         else: next.player

    next = %{next | player: player}

    packets =
      Enum.map(events, fn
        {:update, id, rung, _reapply} -> Packets.update_effect(player.entity_id, id, rung, false)
        {:remove, id} -> Packets.remove_effect(player.entity_id, id)
      end)

    send_packets(next, packets)

    next
    |> Valimc.Player.Movement.publish_movement_speed()
    |> Valimc.Player.Movement.publish_absorption()
    |> Valimc.Player.Movement.publish_jump_boost()
  end

  def tick_effects(state), do: state

  def reset_effect_fall(%{life_stage: :alive} = state) do
    player = Valimc.PlayerTravelEffects.reset_fall(state.player)
    if player.motion != state.player.motion, do: Players.update(self(), player)
    %{state | player: player}
  end

  def reset_effect_fall(state), do: state

  def apply_effect_action(state, :none), do: state

  def apply_effect_action(state, {:exhaust, amount}) do
    if state.player.abilities.invulnerable do
      state
    else
      food = PlayerFood.exhaust(state.player.food, amount)
      player = %{state.player | food: food}
      if food != state.player.food, do: Players.update(self(), player)
      %{state | player: player}
    end
  end

  def apply_effect_action(state, {:heal, amount}) do
    health = heal(state.player.health, amount)

    if health.value == state.player.health.value do
      state
    else
      player = %{state.player | health: health}
      state = %{state | player: player}
      Players.update(self(), player)
      packet = Packets.player_health(player)
      send_packets(state, [Packets.health(health, player.food), packet])
      Valimc.Player.Movement.broadcast_player_packet(state, packet)
    end
  end

  def apply_effect_action(state, {:hurt, source, amount}) do
    {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
    {_, state} = apply_damage(state, selected, source)
    state
  end

  def observe_burning(%{life_stage: stage} = state, _, _, _) when stage != :alive,
    do: %{state | fire_damage_due: false}

  def observe_burning(state, fluid, due, _powder) do
    # Burn requests are bounded while geometry is delayed. They are consumed only
    # against this fresh body sample; lava suppresses the concurrent on-fire hit.
    pending = state.fire_damage_due
    state = %{state | fire_damage_due: false}

    state =
      if pending and not fluid.lava do
        {:ok, selected} = PlayerHealth.hurt_window(state.player.health, 1.0)
        {_, next} = apply_damage(state, selected, :on_fire, state.environment_effects)
        next
      else
        state
      end

    if state.life_stage != :alive or state.player.game_mode.current == :spectator do
      %{state | fire_contacts_active: false}
    else
      previous = state.player.fire_ticks
      state = %{state | fire_contacts_active: fluid.fire_contacts.active}

      state =
        if due do
          Enum.reduce_while(fluid.fire_contacts.operations, state, fn operation, state ->
            if state.life_stage == :alive,
              do: {:cont, apply_fire_contact(state, operation)},
              else: {:halt, state}
          end)
        else
          state
        end

      if due and state.life_stage == :alive do
        state =
          if Map.get(fluid, :rain, false) and Valimc.World.Clock.weather().wet,
            do: apply_fire_contact(state, :extinguish),
            else: state

        ticks = state.player.fire_ticks
        ticks = if ticks <= 0 and ticks <= previous, do: -20, else: ticks
        %{state | player: %{state.player | fire_ticks: ticks}}
      else
        state
      end
    end
  end

  def apply_fire_contact(state, :clear_freeze),
    do: %{
      state
      | player: %{state.player | environment: %{state.player.environment | frozen_ticks: 0}}
    }

  def apply_fire_contact(state, :fire_ignite) do
    {:ok, ignition} =
      Valimc.PlayerBurning.fire(
        state.player.fire_ticks,
        false,
        Valimc.PlayerArmor.attributes(state.inventory).burning_time,
        state.player.abilities.invulnerable
      )

    %{state | player: %{state.player | fire_ticks: ignition.ticks}}
  end

  def apply_fire_contact(state, :lava_ignite) do
    {:ok, ignition} =
      Valimc.PlayerBurning.lava(
        state.player.fire_ticks,
        false,
        Valimc.PlayerArmor.attributes(state.inventory).burning_time,
        state.player.abilities.invulnerable
      )

    %{state | player: %{state.player | fire_ticks: ignition.ticks}}
  end

  def apply_fire_contact(state, :lava_hurt),
    do: apply_fire_contact(state, {:damage, :lava, 4.0})

  def apply_fire_contact(state, {:damage, source, amount}) do
    {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
    {_, state} = apply_damage(state, selected, source)
    state
  end

  def apply_fire_contact(state, :extinguish) do
    {:ok, ticks} = Valimc.PlayerBurning.clear(state.player.fire_ticks)
    %{state | player: %{state.player | fire_ticks: ticks}}
  end

  def observe_environment(state, powder, submerged, eye_water, fluid) do
    due = state.simulation_due
    previous = state.player.environment
    allowed = PlayerEnvironment.can_freeze?(state.player, state.inventory)

    environment =
      PlayerEnvironment.observe(
        previous,
        powder,
        state.simulation_due,
        not allowed
      )

    player = %{state.player | environment: environment}
    state = observe_burning(%{state | player: player}, fluid, due, powder)

    {damage_due, environment} =
      PlayerEnvironment.consume_damage(state.player.environment, allowed)

    player = %{state.player | environment: environment}

    if environment.frozen_ticks != previous.frozen_ticks or
         (previous.powder_snow and not powder) do
      send_packets(state, [Packets.player_environment(player)])
    end

    Players.update(self(), player)
    state = %{state | player: player, simulation_due: false, mining_water: eye_water}
    state = if due, do: observe_air(state, submerged), else: state

    if damage_due do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, 1.0)
      {_, state} = apply_damage(state, selected, :freeze, state.environment_effects)
      state
    else
      state
    end
  end

  def observe_air(state, submerged) do
    previous = Valimc.PlayerAir.supply(state.player)
    oxygen = Valimc.PlayerAir.oxygen_bonus(state.inventory)
    spend = submerged and not state.player.abilities.invulnerable and state.air_policy == :none
    draw = if oxygen > 0 and spend, do: :rand.uniform_real(), else: 0.0

    {air, damage} =
      Valimc.PlayerAir.tick(
        previous,
        submerged,
        state.player.abilities.invulnerable,
        oxygen,
        draw,
        state.air_policy
      )

    player = %{state.player | air_supply: air}
    state = %{state | player: player}

    if air != previous do
      packet = Packets.player_air(player)
      send_packets(state, [packet])
      Valimc.Player.Movement.broadcast_player_packet(state, packet)
      Players.update(self(), player)
    end

    if damage > 0 do
      bubbles = Packets.drowning_bubbles(player.entity_id)
      send_packets(state, [bubbles])
      Valimc.Player.Movement.broadcast_player_packet(state, bubbles)
      {:ok, selected} = PlayerHealth.hurt_window(player.health, damage)
      {_, state} = apply_damage(state, selected, :drown, state.environment_effects)
      state
    else
      state
    end
  end
end
