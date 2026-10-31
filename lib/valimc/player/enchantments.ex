defmodule Valimc.Player.Enchantments do
  @moduledoc """
  Enchantments' post-attack effects as a player meets them (VMC-037q,
  `EnchantmentHelper.doPostAttackEffectsWithItemSource`), through the
  engine (`Valimc.Living.Enchant`):

  - `struck/3`: a hit that hurt the player. Its worn pieces' effects run
    (enchanted victim: Thorns hurts the attacker and wears the piece), then
    those of a melee attacker's weapon (enchanted attacker: Fire Aspect sets
    the player alight).
  - `attacked/2`: what the player's own hit on a mob left for the player
    (the mob's Thorns), from the hurt mob's outcome.

  Actions on the player apply in its session; a hurt to a mob goes through
  the hurt path of the group that owns it.
  """
  alias Valimc.Data.{EffectTypes, EntityTypes, Grid}
  alias Valimc.Living.{Burning, Durability, Enchant}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{CreativeInventory, Vitals}
  alias Valimc.Protocol.DamageTypes
  alias Valimc.World
  alias Valimc.World.Region

  # Worn and held slots in `EquipmentSlot.VALUES` order, with their
  # inventory slots (the main hand's is the selected hotbar slot).
  @slots [mainhand: nil, offhand: 45, feet: 8, legs: 7, chest: 6, head: 5]
  @player EntityTypes.id("minecraft:player")

  @doc "The player as requirements read it."
  def view(state) do
    player = state.player

    Enchant.entity(
      type_id: @player,
      on_ground: player.motion.on_ground,
      fall_distance: player.motion.fall_distance * 1.0,
      player: {Atom.to_string(player.game_mode.current), player.food.level}
    )
  end

  defp attacker_view(%{type: type}), do: Enchant.entity(type_id: EntityTypes.id(type))

  @doc """
  The enchantments' per-tick effects on the player (VMC-037q,
  `LivingEntity.baseTick`): `runLocationChangedEffects` when its block
  position changes (Soul Speed's speed and wear on soul blocks), and each
  equipped piece's `tick` effects (Soul Speed's particles and sound). The
  active location effects and their modifiers are the session's
  (`enchant_location`).
  """
  def tick(%{life_stage: :alive, phase: :play} = state) do
    player = state.player
    block = {floor(player.x), floor(player.y), floor(player.z)}

    location =
      Map.get(state, :enchant_location, %{block: nil, active: [], modifiers: %{}, items: %{}})

    view = moving_view(state)
    before = location.modifiers
    items = Map.new(@slots, fn {slot, _} -> {slot, Enchant.levels(piece(state, slot))} end)

    # A changed piece stops its location effects and the new one starts
    # (`collectEquipmentChanges`); a new block runs them all.
    {state, location} =
      Enum.reduce(@slots, {state, location}, fn {slot, _}, {state, location} ->
        old = Map.get(location.items, slot, [])

        if items[slot] == old do
          {state, location}
        else
          {actions, active} = Enchant.stop_location(slot, old, location.active)

          acc =
            Enum.reduce(
              actions,
              {state, %{location | active: active}},
              &location_action(&2, &1, slot)
            )

          if block == location.block, do: changed_in(acc, slot, items[slot], view), else: acc
        end
      end)

    location = %{location | items: items}

    {state, location} =
      if block != location.block do
        Enum.reduce(@slots, {state, %{location | block: block}}, fn {slot, _}, acc ->
          changed_in(acc, slot, items[slot], view)
        end)
      else
        {state, location}
      end

    state =
      state
      |> Map.put(:enchant_location, location)
      |> publish(before, location.modifiers)

    Enum.reduce(@slots, state, fn {slot, index}, state ->
      case Inventory.get(state.inventory, index || 36 + state.inventory.selected) do
        nil ->
          state

        stack ->
          case Enchant.levels(stack) do
            [] ->
              state

            levels ->
              :tick
              |> Enchant.entity_hook(levels, %{this: view}, slot)
              |> Enum.reduce(state, &tick_action(&2, &1))
          end
      end
    end)
  end

  def tick(state), do: state

  # The player as location and tick requirements read it: the block below
  # that affects its movement, its flying, its speed in blocks a second.
  defp moving_view(state) do
    player = state.player
    below = {floor(player.x), floor(player.y - 0.500001), floor(player.z)}

    affected =
      case World.View.block(World.View.new(player.dimension), below) do
        nil -> nil
        block_state -> Valimc.Data.Blocks.block_id(block_state)
      end

    {mx, _, mz} = player.motion.known_movement

    %{
      view(state)
      | affected_by: affected,
        flying: player.abilities.flying,
        horizontal_speed: :math.sqrt(mx * mx + mz * mz) * 20.0,
        tick_count: Valimc.World.GameTick.current(),
        can_see_sky: false
    }
  end

  defp piece(state, slot) do
    index = Keyword.fetch!(@slots, slot) || 36 + state.inventory.selected
    Inventory.get(state.inventory, index)
  end

  # `runLocationChangedEffects` of the piece in `slot`.
  defp changed_in(acc, _slot, [], _view), do: acc

  defp changed_in({state, location}, slot, levels, view) do
    {actions, active} = Enchant.location_changed(slot, levels, location.active, %{this: view})
    Enum.reduce(actions, {state, %{location | active: active}}, &location_action(&2, &1, slot))
  end

  defp location_action({state, location}, {:add_modifier, attribute, id, amount, op}, _slot) do
    modifiers =
      Map.update(
        location.modifiers,
        attribute,
        [{id, amount, op}],
        &(List.keydelete(&1, id, 0) ++ [{id, amount, op}])
      )

    {state, %{location | modifiers: modifiers}}
  end

  defp location_action({state, location}, {:remove_modifier, attribute, id}, _slot) do
    modifiers = Map.update(location.modifiers, attribute, [], &List.keydelete(&1, id, 0))
    {state, %{location | modifiers: modifiers}}
  end

  defp location_action({state, location}, {:item_damage, n}, slot) do
    index = Keyword.fetch!(@slots, slot) || 36 + state.inventory.selected
    {wear(state, index, n), location}
  end

  # Frost Walker's ice waits for frosted ice's melting (VMC-037q, q1b).
  defp location_action(acc, _action, _slot), do: acc

  @doc "The modifiers the active location effects add to `attribute` (Soul Speed's speed)."
  def location_modifiers(state, attribute),
    do:
      state
      |> Map.get(:enchant_location, %{modifiers: %{}})
      |> Map.get(:modifiers)
      |> Map.get(attribute, [])

  # The attributes whose location modifiers changed reach the client:
  # movement speed with the effects' (`Movement.publish_movement_speed/1`
  # reads `location_modifiers/2`), the others alone.
  defp publish(state, before, modifiers) when before == modifiers, do: state

  defp publish(state, before, modifiers) do
    changed =
      for attribute <- Enum.uniq(Map.keys(before) ++ Map.keys(modifiers)),
          Map.get(before, attribute, []) != Map.get(modifiers, attribute, []),
          do: attribute

    Enum.reduce(changed, state, fn
      "minecraft:movement_speed", state ->
        Valimc.Player.Movement.publish_movement_speed(state)

      "minecraft:" <> name = attribute, state ->
        fact = Valimc.Living.Attributes.fetch(name)

        Valimc.Protocol.Codec.send_packets(state, [
          Valimc.Protocol.Packets.attribute(
            state.player.entity_id,
            {fact["id"], Valimc.Living.Weapons.player_base(attribute),
             Map.get(modifiers, attribute, [])}
          )
        ])

        state
    end)
  end

  defp tick_action(state, {:particles, spec}) do
    player = state.player
    {width, height} = {0.6, 1.8}
    {mx, my, mz} = player.motion.known_movement

    coordinate = fn {in_box, offset, scale}, position, center, span ->
      base = if in_box, do: center + (:rand.uniform() - 0.5) * span * scale, else: position
      base + offset
    end

    velocity = fn {scale, provider}, movement -> movement * scale + sample(provider) end
    {hx, hy} = {spec.horizontal, spec.vertical}

    position =
      {coordinate.(hx, player.x, player.x, width),
       coordinate.(hy, player.y, player.y + height / 2.0, height),
       coordinate.(hx, player.z, player.z, width)}

    packet =
      Valimc.Protocol.Particles.moving(
        spec.particle,
        position,
        {velocity.(spec.horizontal_velocity, mx), velocity.(spec.vertical_velocity, my),
         velocity.(spec.horizontal_velocity, mz)},
        sample(spec.speed)
      )

    Valimc.Player.Movement.broadcast_player_packet(state, packet)
    Valimc.Protocol.Codec.send_packets(state, [packet])
    state
  end

  defp tick_action(state, {:sound, name, volume, pitch}) do
    %{x: x, y: y, z: z} = state.player
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    packet = Valimc.Protocol.CombatPackets.sound(name, "player", {x, y, z}, volume, pitch, seed)
    Valimc.Player.Movement.broadcast_player_packet(state, packet)
    Valimc.Protocol.Codec.send_packets(state, [packet])
    state
  end

  defp tick_action(state, _action), do: state

  defp sample({min, max}), do: min + :rand.uniform() * (max - min)
  defp sample(value), do: value

  @doc "The post-attack effects of `hit` (`Player.Hurt`'s) after it hurt the player."
  def struck(state, %{attacker: %{player: false} = attacker} = hit, result)
      when result in [:hurt, :dead] do
    direct = hit[:direct] || attacker
    source = hit.source

    ctx = %{
      this: view(state),
      attacker: attacker_view(attacker),
      direct: attacker_view(direct),
      damage:
        {DamageTypes.id(Valimc.Living.DamageSource.type(source)), direct.uuid == attacker.uuid}
    }

    state =
      Enum.reduce(@slots, state, fn {slot, index}, state ->
        index = index || 36 + state.inventory.selected

        case Inventory.get(state.inventory, index) do
          nil ->
            state

          stack ->
            :victim
            |> Enchant.post_attack(Enchant.levels(stack), slot, ctx)
            |> Enum.reduce(state, fn
              {_, {:item_damage, n}}, state -> wear(state, index, n)
              {:victim, action}, state -> on_self(state, action, attacker)
              {_, action}, state -> on_attacker(state, attacker, action)
            end)
        end
      end)

    # A melee hit's weapon (`doPostAttackEffects`: the attacker's weapon).
    case attacker do
      %{mainhand: %{} = weapon} when direct.uuid == attacker.uuid ->
        :attacker
        |> Enchant.post_attack(Enchant.levels(weapon), :mainhand, ctx)
        |> Enum.reduce(state, fn
          {:victim, action}, state -> on_self(state, action, attacker)
          _, state -> state
        end)

      _ ->
        state
    end
  end

  def struck(state, _hit, _result), do: state

  @doc "Actions a hurt mob's outcome left for the attacking player (its Thorns)."
  def attacked(state, %{post_attack: actions} = outcome, mob) do
    Enum.reduce(actions, state, &on_self(&2, &1, mob_attacker(mob, outcome)))
  end

  def attacked(state, _outcome, _mob), do: state

  defp mob_attacker(view, _outcome),
    do: %{uuid: view.uuid, entity_id: view.entity_id, player: false, type: view.type}

  # An action on the player itself.
  defp on_self(state, {:ignite, seconds}, _cause) do
    living = state.player.living
    factor = Valimc.Living.Armor.enchanted_value(attributes(state), "minecraft:burning_time")

    case Burning.ignite_seconds(
           living.fire_ticks,
           seconds,
           factor,
           state.player.abilities.invulnerable
         ) do
      {:ok, %{ticks: ticks}} -> put_in(state.player.living.fire_ticks, ticks)
      _ -> state
    end
  end

  defp on_self(state, {:mob_effect, "minecraft:" <> name, ticks, amplifier}, _cause) do
    case Vitals.apply_effect(state, EffectTypes.id(name), [{ticks, amplifier, false, true, true}]) do
      {:ok, _, state} -> state
      _ -> state
    end
  end

  defp on_self(state, {:damage, amount, "minecraft:" <> type}, cause) do
    {_, state} =
      Valimc.Player.Hurt.hurt(state, %{
        source: String.to_existing_atom(type),
        amount: amount,
        attacker: cause,
        direct: cause
      })

    state
  end

  defp on_self(state, {:exhaustion, amount}, _cause),
    do: Vitals.apply_effect_action(state, {:exhaust, amount})

  defp on_self(state, _action, _cause), do: state

  # An action on the mob that hurt the player (Thorns' damage), through the
  # hurt path of the group that owns it, caused by the player.
  defp on_attacker(state, attacker, {:damage, amount, "minecraft:" <> type}) do
    player = state.player

    me = %{
      uuid: player.uuid,
      entity_id: player.entity_id,
      player: true,
      type: "minecraft:player",
      mainhand: Inventory.held(state.inventory, :main)
    }

    with %{} = view <- mob_view(state, attacker.uuid),
         {:ok, {pid, _} = owner} <-
           World.existing_owner(
             Grid.section(player.dimension, Grid.region_key(view.chunk), :section)
           ),
         true <- pid == self() do
      Region.hurt_entity(owner, attacker.uuid, %{
        source: String.to_existing_atom(type),
        amount: amount,
        attacker: me,
        direct: me,
        position: {player.x, player.y, player.z}
      })
    end

    state
  end

  defp on_attacker(state, _attacker, _action), do: state

  defp mob_view(state, uuid) do
    %{x: x, z: z, dimension: dimension} = state.player
    {cx, cz} = Grid.chunk_key(x, z)
    chunks = for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}
    {views, _} = World.visible_entities(MapSet.new(chunks, &Grid.section(dimension, &1)), chunks)
    Enum.find_value(views, fn {_, v} -> if Map.get(v, :uuid) == uuid, do: v end)
  end

  defp attributes(state),
    do: Valimc.Living.Armor.attributes(Valimc.Living.Armor.equipment(state.inventory))

  # `hurtAndBreak` of the piece in inventory slot `index` (Thorns' cost).
  defp wear(state, index, n) do
    stack = Inventory.get(state.inventory, index)
    creative = state.player.game_mode.current == :creative
    {after_wear, _broken} = Durability.hurt_and_break(stack, n, creative)

    slots =
      if after_wear,
        do: Map.put(state.inventory.slots, index, after_wear),
        else: Map.delete(state.inventory.slots, index)

    inventory = %{state.inventory | slots: slots} |> Inventory.advance()
    CreativeInventory.resync_inventory(%{state | inventory: inventory})
  end
end
