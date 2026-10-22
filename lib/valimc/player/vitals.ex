defmodule Valimc.Player.Vitals do
  @moduledoc "Player vitals in the player's session: food, health, damage, death and respawn, burning, effects, environment and air (VMC-069)."

  alias Valimc.Protocol.{ClientTick, Packets}
  alias Valimc.Data.EffectTypes

  import Valimc.Protocol.Codec,
    only: [send_packets: 2]

  alias Valimc.Menus.Inventory
  alias Valimc.Player.{PlayerList, Food, Input, Life}
  alias Valimc.World

  alias Valimc.Living.{
    Air,
    Armor,
    Attributes,
    Burning,
    Damage,
    DamageSource,
    Effects,
    Freezing,
    Health
  }

  require Logger
  import Bitwise
  @hunger EffectTypes.id("hunger")
  @absorption EffectTypes.id("absorption")

  def apply_landing(state, nil), do: state

  def apply_landing(state, call) do
    {:ok, jump} = Attributes.jump_boost(state.player.living.effects)

    {:ok, amount} =
      Valimc.Living.FallDamage.calculate(
        call.distance,
        call.multiplier,
        %Valimc.Living.FallDamage{safe_distance: jump.safe_distance}
      )

    if amount > 0 do
      {:ok, selected} = Health.hurt_window(state.player.living.health, amount)
      {_, state} = apply_damage(state, selected, call.source)
      state
    else
      state
    end
  end

  def apply_void_damage(%{life_stage: :alive} = state) do
    {min_y, _height} = Valimc.World.Dimension.bounds()
    amount = Damage.void(state.player.y, min_y)

    if amount > 0 do
      {:ok, selected} = Health.hurt_window(state.player.living.health, amount)
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
      {:ok, selected} = Health.hurt_window(state.player.living.health, amount)
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
    food = state.player.food |> Food.exhaust(jump) |> Food.exhaust(travel)
    player = %{state.player | food: food}
    if food != state.player.food, do: PlayerList.update(state.connection, player)
    %{state | player: player}
  end

  def tick_food(%{life_stage: :alive} = state) do
    phase = rem(state.simulation_clock.tick - state.food_tick_origin, 20)

    if Food.idle?(state.player.food, state.player.living.health, phase),
      do: state,
      else: advance_food(state, phase)
  end

  def tick_food(state), do: state

  def advance_food(state, phase) do
    {difficulty, regeneration} = World.Clock.survival()
    before = state.player
    previous = before.living.health

    {food, peaceful_heal} =
      Food.peaceful(before.food, previous, difficulty, regeneration, phase)

    health = heal(previous, peaceful_heal)
    {food, effect} = Food.tick(food, health, difficulty, regeneration)
    health = heal(health, effect.heal)

    state =
      if before.food != food or previous != health do
        player = %{before | food: food, living: %{before.living | health: health}}
        PlayerList.update(state.connection, player)
        %{state | player: player}
      else
        state
      end

    # Native replication observes health, food and whether saturation crossed zero.
    if previous.value != health.value or before.food.level != food.level or
         before.food.saturation == 0 != (food.saturation == 0),
       do: send_packets(state, [Valimc.Player.Packets.health(health, food)])

    if previous.value != health.value,
      do: send_packets(state, [Valimc.Player.Packets.player_health(state.player)])

    if effect.damage > 0 do
      {:ok, selected} = Health.hurt_window(health, effect.damage)
      {_, state} = apply_damage(state, selected, :starve)
      state
    else
      state
    end
  end

  def heal(health, amount) do
    if health.value > 0 and amount > 0 do
      {:ok, next} = Health.set(health, health.value + amount)
      next
    else
      health
    end
  end

  @doc """
  A player's hit through `Living.Damage`: falls and stalagmites spare a player
  who may fly, a client that has not loaded is immune, creative players' armor
  does not wear, and food pays the source's exhaustion.
  """
  def resolve_damage(player, inventory, selected, source, effects) do
    equipment = Armor.equipment(inventory)

    result =
      Damage.resolve(player.living, equipment, selected, source,
        effects: effects,
        invulnerable: player.abilities.invulnerable,
        immune:
          (source in [:fall, :stalagmite] and player.abilities.may_fly) or
            not Input.loaded?(player.input),
        infinite: player.abilities.infinite_materials
      )

    case result do
      {:ok, %{living: living, equipment: worn, broken: broken, exhaustion: exhaustion}} ->
        food = if exhaustion, do: Food.exhaust(player.food, exhaustion), else: player.food

        inventory =
          if worn == equipment, do: inventory, else: Armor.put_equipment(inventory, worn)

        {:ok,
         %{player: %{player | living: living, food: food}, inventory: inventory, broken: broken}}

      reason ->
        reason
    end
  end

  def apply_damage(state, selected, source, effects \\ nil) do
    result =
      if state.life_stage != :alive,
        do: :ignored,
        else:
          resolve_damage(
            state.player,
            state.inventory,
            selected,
            source,
            effects || state.player.living.effects
          )

    case result do
      reason when reason in [:ignored, :immune] ->
        {reason, state}

      {:ok, %{player: player, inventory: inventory, broken: broken}} ->
        health = player.living.health

        state =
          if inventory == state.inventory do
            %{state | player: player}
          else
            %{state | player: player, inventory: inventory}
            |> Valimc.Player.CreativeInventory.resync_inventory()
            |> Valimc.Player.ItemUse.publish_equipment()
          end

        for {slot, _stack} <- broken do
          packet = Valimc.Living.Packets.armor_break(player.entity_id, slot)
          send_packets(state, [packet])
          Valimc.Player.Movement.broadcast_player_packet(state, packet)
        end

        state =
          if health.value <= 0 do
            state =
              state
              |> Valimc.Player.ItemUse.stop_item_use()
              |> Valimc.Player.Mining.cancel_mining()

            dead_state(state)
          else
            state
          end

        state =
          if health.value <= 0, do: Valimc.Player.Menus.close(state), else: state

        PlayerList.update(state.connection, state.player)

        if selected.notify do
          packet = Packets.damage_event(state.player.entity_id, source)
          send_packets(state, [packet])
          Valimc.Player.Movement.broadcast_player_packet(state, packet)
        end

        send_packets(state, [
          Valimc.Player.Packets.health(state.player.living.health, state.player.food),
          Valimc.Player.Packets.player_health(state.player)
        ])

        state = Valimc.Player.Movement.publish_absorption(state)
        state = if health.value <= 0, do: death_notice(state, true, source), else: state
        {if(health.value <= 0, do: :dead, else: :hurt), continue_life(state)}
    end
  end

  def dead_state(state) do
    %{
      state
      | player: Life.die(state.player),
        motion_window: nil,
        pose_checked: nil,
        pose_generation: state.pose_generation + 1,
        life_stage: :sealing_death,
        fire_damage_due: false,
        fire_contacts_active: false
    }
  end

  def death_notice(state, announce, source \\ :fall) do
    message =
      DamageSource.death_message(
        state.player.name,
        if(announce, do: source, else: :generic)
      )

    send_packets(state, [
      Valimc.Player.Packets.player_pose(state.player),
      Packets.death(state.player.entity_id, message),
      Packets.death_animation(state.player.entity_id)
    ])

    Valimc.Player.Movement.broadcast_player_packet(
      state,
      Packets.death_animation(state.player.entity_id)
    )

    # Vanilla's `broadcastSystemMessage` also prints the message to the console.
    if announce do
      Logger.info(Valimc.Text.Render.string(text_tag(message)))
      PlayerList.broadcast({:chat, message})
    end

    state
  end

  defp text_tag(%Valimc.Protocol.ServerText{tag: tag}), do: tag
  defp text_tag(tag), do: tag

  # A death runs its stages at once: the inventory and the drops change in one
  # callback, so the group's commit makes them durable together (VMC-077i3).
  def continue_life(%{life_stage: :sealing_death, phase: :play} = state),
    do: continue_life(%{state | life_stage: :dropping})

  # The death drops scatter at once (`Player.dropAllDeathLoot`): the
  # inventory, but items with Curse of Vanishing are destroyed, and orbs worth
  # seven points a level, at most 100 (`getBaseExperienceReward`), none for a
  # spectator. The respawned player starts without experience. Outside its
  # group's sections the player keeps them until it is in one.
  def continue_life(%{life_stage: :dropping, phase: :play} = state) do
    {:ok, inventory, stacks, _destroyed} = Inventory.death(state.inventory)
    player = state.player

    points =
      if player.game_mode.current == :spectator,
        do: 0,
        else: min(player.progression.experience.level * 7, 100)

    orbs = Valimc.Entity.ExperienceOrbs.drop({player.x, player.y, player.z}, points)

    case Valimc.Player.Items.drop(state, inventory, stacks, :scattered, orbs) do
      {:ok, state} ->
        continue_life(%{state | life_stage: :dead})

      :error ->
        state
    end
  end

  def continue_life(%{life_stage: :dead, respawn_requested: true} = state) do
    spawn = Valimc.World.PlayerSpawn.find()
    finish_respawn(state, Life.respawn(state.player, spawn))
  end

  def continue_life(state), do: state

  def finish_respawn(state, player) do
    # Post effects (`/posteffect`) do not survive a respawn, as in vanilla.
    post_effects =
      if Map.get(state.player, :post_effects, []) != [],
        do: [Valimc.Player.PostEffects.packet([])],
        else: []

    player = Map.put(player, :post_effects, [])

    state = %{
      state
      | life_stage: :alive,
        air_policy: :none,
        environment_effects: %{},
        movement_speed_view: nil,
        absorption_view: nil,
        jump_boost_view: nil,
        fire_damage_due: false,
        fire_contacts_active: false,
        respawn_requested: false,
        food_tick_origin: state.simulation_clock.tick,
        client_tick: %ClientTick{}
    }

    # A death in another dimension respawns in the spawn's (VMC-026b, VMC-077a).
    Valimc.Player.Level.respawn(
      state,
      player,
      Inventory.new(player.abilities.infinite_materials),
      keep: 0,
      unload: true,
      motion: :reset,
      post_effects: post_effects
    )
  end

  def tick_burning(%{life_stage: stage} = state) when stage != :alive,
    do: %{state | fire_damage_due: false}

  def tick_burning(state) do
    living = state.player.living

    {:ok, burning} =
      Burning.tick(living.fire_ticks, false, false, state.player.abilities.invulnerable)

    player = %{state.player | living: %{living | fire_ticks: burning.ticks}}
    burning_now = burning.ticks > 0
    burning_before = living.fire_ticks > 0
    if burning_now != burning_before, do: PlayerList.update(state.connection, player)

    %{
      state
      | player: player,
        pose_checked: if(burning_before and not burning_now, do: nil, else: state.pose_checked),
        fire_damage_due:
          burning.ticks > 0 and not Damage.status_immune?(living.effects, :on_fire) and
            (state.fire_damage_due or burning.damage > 0)
    }
  end

  @doc "Add (`[rung]`) or `:remove` a live effect: `{:ok, changed, state}` or an error."
  def apply_effect(state, id, incoming) do
    living = state.player.living

    result =
      if incoming == :remove,
        do: Effects.remove(living.effects, id),
        else: Effects.add(living.effects, id, incoming)

    case result do
      {:ok, effects, changed} ->
        new = not Map.has_key?(living.effects, id)
        dose = if id == @absorption and incoming != :remove, do: elem(hd(incoming), 1)
        absorption = Health.reconcile_absorption(living.absorption, effects, dose)
        player = %{state.player | living: %{living | effects: effects, absorption: absorption}}
        next = %{state | player: player}

        if changed do
          packet =
            if incoming == :remove,
              do: Packets.remove_effect(player.entity_id, id),
              else:
                Valimc.Living.Packets.update_effect(player.entity_id, id, hd(effects[id]), new)

          send_packets(next, [packet])
        end

        PlayerList.update(state.connection, player)
        {:ok, changed, publish_effect_attributes(next)}

      error ->
        error
    end
  end

  defp publish_effect_attributes(state) do
    state
    |> Valimc.Player.Movement.publish_movement_speed()
    |> Valimc.Player.Movement.publish_absorption()
    |> Valimc.Player.Movement.publish_jump_boost()
  end

  def tick_effects(%{life_stage: :alive, player: %{living: %{effects: effects}}} = state)
      when map_size(effects) > 0 do
    before_level = Attributes.absorption_level(effects)
    depleted = Map.has_key?(effects, @absorption) and state.player.living.absorption == 0
    effects = if depleted, do: Map.delete(effects, @absorption), else: effects
    {:ok, after_effects, events} = Effects.tick(effects)
    events = if depleted, do: [{:remove, @absorption} | events], else: events
    # Requests read pre-decrement heads. Publish the final duration map to this
    # owner before health application can seal a durable death snapshot.
    state = put_living(state, effects: after_effects)
    unsigned_age = band(state.simulation_clock.tick, 0xFFFFFFFF)
    age = if unsigned_age >= 2_147_483_648, do: unsigned_age - 4_294_967_296, else: unsigned_age

    next =
      Enum.reduce_while(Effects.periodic_ids(), state, fn id, current ->
        cond do
          current.life_stage != :alive ->
            {:halt, current}

          not Map.has_key?(effects, id) ->
            {:cont, current}

          true ->
            {:ok, action} =
              if id == @hunger,
                do: Effects.hunger(effects[id]),
                else: Effects.periodic(id, effects[id], age, current.player.living.health)

            {:cont, apply_effect_action(current, action)}
        end
      end)

    living = next.player.living

    {next, events} =
      if next.life_stage == :alive and living.absorption == 0 and
           Map.has_key?(living.effects, @absorption) do
        events = Enum.reject(events, fn event -> elem(event, 1) == @absorption end)

        {put_living(next, effects: Map.delete(living.effects, @absorption)),
         events ++ [{:remove, @absorption}]}
      else
        {next, events}
      end

    # Damage requests above spend the pre-expiry pool; promotion/removal then
    # clamps it to the final maximum without starting another dose.
    living = next.player.living

    next =
      if next.life_stage == :alive and
           before_level != Attributes.absorption_level(living.effects),
         do:
           put_living(next,
             absorption: Health.reconcile_absorption(living.absorption, living.effects)
           ),
         else: next

    packets =
      Enum.map(events, fn
        {:update, id, rung, _reapply} ->
          Valimc.Living.Packets.update_effect(next.player.entity_id, id, rung, false)

        {:remove, id} ->
          Packets.remove_effect(next.player.entity_id, id)
      end)

    send_packets(next, packets)
    publish_effect_attributes(next)
  end

  def tick_effects(state), do: state

  defp put_living(state, fields),
    do: %{state | player: %{state.player | living: struct!(state.player.living, fields)}}

  def reset_effect_fall(%{life_stage: :alive} = state) do
    if Attributes.resets_fall?(state.player.living.effects) do
      player = %{state.player | motion: %{state.player.motion | fall_distance: 0.0}}
      if player.motion != state.player.motion, do: PlayerList.update(state.connection, player)
      %{state | player: player}
    else
      state
    end
  end

  def reset_effect_fall(state), do: state

  def apply_effect_action(state, :none), do: state

  def apply_effect_action(state, {:exhaust, amount}) do
    if state.player.abilities.invulnerable do
      state
    else
      food = Food.exhaust(state.player.food, amount)
      player = %{state.player | food: food}
      if food != state.player.food, do: PlayerList.update(state.connection, player)
      %{state | player: player}
    end
  end

  def apply_effect_action(state, {:heal, amount}) do
    health = heal(state.player.living.health, amount)

    if health.value == state.player.living.health.value do
      state
    else
      state = put_living(state, health: health)
      player = state.player
      PlayerList.update(state.connection, player)

      send_packets(state, [
        Valimc.Player.Packets.health(health, player.food),
        Valimc.Player.Packets.player_health(player)
      ])

      state
    end
  end

  def apply_effect_action(state, {:hurt, source, amount}) do
    {:ok, selected} = Health.hurt_window(state.player.living.health, amount)
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
        {:ok, selected} = Health.hurt_window(state.player.living.health, 1.0)
        {_, next} = apply_damage(state, selected, :on_fire, state.environment_effects)
        next
      else
        state
      end

    if state.life_stage != :alive or state.player.game_mode.current == :spectator do
      %{state | fire_contacts_active: false}
    else
      previous = state.player.living.fire_ticks
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

        ticks = state.player.living.fire_ticks
        ticks = if ticks <= 0 and ticks <= previous, do: -20, else: ticks
        put_living(state, fire_ticks: ticks)
      else
        state
      end
    end
  end

  def apply_fire_contact(state, :clear_freeze) do
    freezing = state.player.living.freezing
    put_living(state, freezing: %{freezing | frozen_ticks: 0})
  end

  def apply_fire_contact(state, :fire_ignite) do
    {:ok, ignition} =
      Burning.fire(
        state.player.living.fire_ticks,
        false,
        burning_time(state),
        state.player.abilities.invulnerable
      )

    put_living(state, fire_ticks: ignition.ticks)
  end

  def apply_fire_contact(state, :lava_ignite) do
    {:ok, ignition} =
      Burning.lava(
        state.player.living.fire_ticks,
        false,
        burning_time(state),
        state.player.abilities.invulnerable
      )

    put_living(state, fire_ticks: ignition.ticks)
  end

  def apply_fire_contact(state, :lava_hurt),
    do: apply_fire_contact(state, {:damage, :lava, 4.0})

  def apply_fire_contact(state, {:damage, source, amount}) do
    {:ok, selected} = Health.hurt_window(state.player.living.health, amount)
    {_, state} = apply_damage(state, selected, source)
    state
  end

  def apply_fire_contact(state, :extinguish) do
    {:ok, ticks} = Burning.clear(state.player.living.fire_ticks)
    put_living(state, fire_ticks: ticks)
  end

  defp burning_time(state), do: Armor.attributes(Armor.equipment(state.inventory)).burning_time

  def observe_environment(state, powder, submerged, eye_water, fluid) do
    due = state.simulation_due
    previous = state.player.living.freezing

    allowed =
      Freezing.can_freeze?(
        state.player.game_mode.current == :spectator,
        Armor.equipment(state.inventory)
      )

    freezing = Freezing.observe(previous, powder, state.simulation_due, not allowed)
    state = observe_burning(put_living(state, freezing: freezing), fluid, due, powder)
    {damage_due, freezing} = Freezing.consume_damage(state.player.living.freezing, allowed)
    state = put_living(state, freezing: freezing)
    player = state.player

    if freezing.frozen_ticks != previous.frozen_ticks or
         (previous.powder_snow and not powder) do
      send_packets(state, [Valimc.Player.Packets.player_environment(player)])
    end

    PlayerList.update(state.connection, player)
    state = %{state | simulation_due: false, mining_water: eye_water}
    state = if due, do: observe_air(state, submerged), else: state

    if damage_due do
      {:ok, selected} = Health.hurt_window(state.player.living.health, 1.0)
      {_, state} = apply_damage(state, selected, :freeze, state.environment_effects)
      state
    else
      state
    end
  end

  def observe_air(state, submerged) do
    previous = state.player.living.air_supply
    oxygen = Armor.oxygen_bonus(Armor.equipment(state.inventory))
    spend = submerged and not state.player.abilities.invulnerable and state.air_policy == :none
    draw = if oxygen > 0 and spend, do: :rand.uniform_real(), else: 0.0

    {air, damage} =
      Air.tick(
        previous,
        submerged,
        state.player.abilities.invulnerable,
        oxygen,
        draw,
        state.air_policy
      )

    state = put_living(state, air_supply: air)
    player = state.player

    if air != previous do
      send_packets(state, [Valimc.Player.Packets.player_air(player)])
      PlayerList.update(state.connection, player)
    end

    if damage > 0 do
      bubbles = Packets.drowning_bubbles(player.entity_id)
      send_packets(state, [bubbles])
      Valimc.Player.Movement.broadcast_player_packet(state, bubbles)
      {:ok, selected} = Health.hurt_window(player.living.health, damage)
      {_, state} = apply_damage(state, selected, :drown, state.environment_effects)
      state
    else
      state
    end
  end
end
