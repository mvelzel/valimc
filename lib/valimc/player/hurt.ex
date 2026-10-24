defmodule Valimc.Player.Hurt do
  @moduledoc """
  A hit an entity deals a player (VMC-037n): `Player.hurtServer` and
  `LivingEntity.hurtServer` for a mob's melee (`Entity.Combat`'s hit shape),
  run in the player's session. `plan/2` is the pure part: the difficulty
  scales a living non-player's hit; a raised shield blocks its share of a hit
  from in front (`BlocksAttacks`, after the block delay) and wears; a partly
  blocked melee hit knocks the blocker back. `hurt/2` then takes the rest
  through the hurt window, armor and absorption (`Vitals.apply_damage/5`),
  knocks the player away from the source unless fully blocked, adds the
  attacker's extra knockback, and plays the shield's block sound and the
  player's hurt or death sound. Knockback reaches the client as its velocity.

  Not modelled yet: shields disabled by axes (no mob wields one before
  VMC-043b), helmet wear from falling blocks, and Thorns.
  """
  alias Valimc.Data.Float32
  alias Valimc.Living.{Armor, Attributes, DamageSource, Durability, Health, Melee, Weapons}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{CreativeInventory, ItemUse, Movement, Use, Vitals}
  alias Valimc.Protocol.{CombatPackets, DamageTypes}
  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @doc """
  The pure part of a hit on a defender: `defender` holds `:position`, `:yaw`
  (where its head faces), `:invulnerable`, `:difficulty` (0 to 3) and
  `:blocking` (`{shield, ticks raised}` or nil). `:ignored`, or
  `%{damage, blocked, shield_wear, knockback}`: the damage left after the
  shield, the share it blocked, the shield's wear, and the knockback a partly
  blocked melee hit adds (`{power, direction}` or nil).
  """
  def plan(hit, defender) do
    source = hit.source
    attacker = hit[:attacker]

    damage =
      if DamageSource.scales_with_difficulty?(source, attacker != nil and not attacker.player),
        do: difficulty(defender.difficulty, Float32.round(hit.amount)),
        else: Float32.round(hit.amount)

    cond do
      defender.invulnerable and not DamageSource.is?(source, :bypasses_invulnerability) ->
        :ignored

      damage == 0.0 ->
        :ignored

      true ->
        damage = max(0.0, damage)

        case block(hit, defender, damage) do
          nil ->
            %{damage: damage, blocked: 0.0, shield_wear: 0, knockback: nil}

          {blocks, blocked} ->
            # `blockedByItem`: a partly blocked melee hit knocks the blocker back.
            knockback =
              if blocked > 0.0 and blocked < damage and attacker != nil and
                   not DamageSource.is?(source, :is_projectile),
                 do: {0.5, away(defender.position, hit[:position])}

            %{
              damage: Float32.round(damage - blocked),
              blocked: blocked,
              shield_wear: Melee.shield_wear(blocks.item_damage, blocked),
              knockback: knockback
            }
        end
    end
  end

  @doc """
  Hurt the session's player with `hit` (`%{source, amount, attacker,
  position}` and optionally `:extra_knockback` and `:killer`).
  `{result, state}`: `:hurt`, `:dead`, `:blocked`, or `:ignored`.
  """
  def hurt(%{life_stage: :alive} = state, hit) do
    player = state.player

    defender = %{
      position: {player.x, player.y, player.z},
      yaw: player.yaw,
      invulnerable: player.abilities.invulnerable,
      difficulty: elem(Valimc.World.Clock.difficulty(), 0).level,
      blocking: blocking(state)
    }

    case plan(hit, defender) do
      :ignored ->
        {:ignored, state}

      plan ->
        state = if plan.shield_wear > 0, do: wear_shield(state, plan.shield_wear), else: state

        state =
          case plan.knockback do
            {power, direction} -> knockback(state, power, direction)
            nil -> state
          end

        source = hit.source
        attacker = hit[:attacker]

        {:ok, selected} =
          Health.hurt_window(
            state.player.living.health,
            plan.damage,
            DamageSource.is?(source, :bypasses_cooldown)
          )

        {result, state} =
          Vitals.apply_damage(state, selected, source, nil,
            cause: attacker && attacker.entity_id,
            direct: (hit[:direct] || attacker) && (hit[:direct] || attacker).entity_id,
            blocked: plan.blocked > 0.0,
            killer: hit[:killer] || attacker_name(attacker)
          )

        fully = plan.blocked > 0.0 and plan.damage <= 0.0
        state = if plan.blocked > 0.0 and selected.notify, do: shield_sound(state), else: state

        state =
          if selected.notify and result in [:hurt, :dead] and not fully and
               not DamageSource.is?(source, :no_knockback),
             do:
               knockback(
                 state,
                 Melee.default_knockback(),
                 hit[:direction] || away(defender.position, hit[:position])
               ),
             else: state

        # `playHurtSound`, or the death sound (a player's voice is at pitch 1).
        state =
          cond do
            not selected.notify -> state
            result == :dead -> sound(state, "minecraft:entity.player.death", 1.0, 1.0)
            true -> sound(state, "minecraft:entity.player.hurt", 1.0, 1.0)
          end

        # A push the attacker adds when its hit takes (a hoglin's throw,
        # VMC-043d).
        state =
          case hit[:push] do
            {px, py, pz} when result in [:hurt, :dead] ->
              motion = state.player.motion
              {vx, vy, vz} = motion.velocity
              velocity = {vx + px, vy + py, vz + pz}
              state = %{state | player: %{state.player | motion: %{motion | velocity: velocity}}}
              Movement.send_velocity(state, velocity)
              state

            _ ->
              state
          end

        # What the attacker plays when its hit takes (a cube's attack
        # sound, VMC-043d).
        state =
          case hit[:taken_sound] do
            {name, source, position, volume, pitch} when result in [:hurt, :dead] ->
              <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
              packet = CombatPackets.sound(name, source, position, volume, pitch, seed)
              Movement.broadcast_player_packet(state, packet)
              send_packets(state, [packet])
              state

            _ ->
              state
          end

        state =
          case hit[:extra_knockback] do
            {power, direction} when power > 0 and result in [:hurt, :dead] ->
              knockback(state, power, direction)

            _ ->
              state
          end

        # An iron golem's hit throws the player up (VMC-044a2), less its
        # knockback resistance.
        state =
          case hit[:lift] do
            lift when is_number(lift) and result in [:hurt, :dead] -> lift(state, lift)
            _ -> state
          end

        # A burning arrow or small fireball sets the player on fire (VMC-037o).
        state =
          case hit[:ignite] do
            ticks when is_integer(ticks) and result == :hurt ->
              living = state.player.living
              put_in(state.player.living, %{living | fire_ticks: max(living.fire_ticks, ticks)})

            _ ->
              state
          end

        # What the attacker's hit adds (VMC-043b: a husk's hunger).
        state =
          case hit[:effect] do
            {id, rung} when result == :hurt ->
              case Valimc.Player.Vitals.apply_effect(state, id, [rung]) do
                {:ok, _, next} -> next
                _ -> state
              end

            _ ->
              state
          end

        state =
          if result in [:hurt, :dead] and match?(%{player: false}, attacker),
            do: put_in(state.player.living.last_mob_hurt, Valimc.World.GameTick.current()),
            else: state

        {if(fully, do: :blocked, else: result), state}
    end
  end

  def hurt(state, _hit), do: {:ignored, state}

  @doc "A dragon part pushes first, then admits its living hit against the fresh session."
  def dragon_contact(%{life_stage: :alive} = state, hit, {dx, dy, dz}, wing) do
    if state.player.game_mode.current in [:creative, :spectator] do
      state
    else
      motion = state.player.motion
      {x, y, z} = motion.velocity
      velocity = {x + dx, y + dy, z + dz}
      state = put_in(state.player.motion.velocity, velocity)
      if dx != 0.0 or dy != 0.0 or dz != 0.0, do: Movement.send_velocity(state, velocity)
      at = state.player.living.last_mob_hurt
      recent = wing and at != nil and at >= Valimc.World.GameTick.current() - 2
      if hit.amount > 0.0 and not recent, do: elem(hurt(state, hit), 1), else: state
    end
  end

  def dragon_contact(state, _hit, _push, _wing), do: state

  # `Player.hurtServer`'s difficulty scaling.
  defp difficulty(0, _damage), do: 0.0
  defp difficulty(1, damage), do: min(Float32.round(Float32.round(damage / 2.0) + 1.0), damage)
  defp difficulty(2, damage), do: damage
  defp difficulty(3, damage), do: Float32.round(Float32.round(damage * 3.0) / 2.0)

  # `getItemBlockingWith`: a raised shield, after its block delay.
  defp blocking(state) do
    with %Use{blocking: true} = use <- state.active_use,
         %{} = shield <- Inventory.held(state.inventory, use.hand) do
      {shield, Use.elapsed(use)}
    else
      _ -> nil
    end
  end

  # `applyItemBlocking`: the shield and the share it blocks.
  defp block(hit, defender, damage) do
    with {shield, raised} <- defender.blocking,
         %{} = blocks <- Weapons.blocks_attacks(shield),
         true <- raised >= Melee.block_delay(blocks),
         false <- bypassed?(blocks, hit.source) do
      angle = Melee.blocking_angle(defender.position, defender.yaw, hit[:position])
      {blocks, Melee.blocked(blocks, DamageSource.type(hit.source), damage, angle, &in_set?/2)}
    else
      _ -> nil
    end
  end

  defp bypassed?(%{bypassed_by: set}, source),
    do: is_tuple(set) and in_set?(set, DamageSource.type(source))

  defp in_set?({:tag, tag}, type), do: DamageTypes.tag?(type, tag)
  defp in_set?({:types, types}, type), do: type in types

  # `hurtBlockingItem`: the shield in its hand wears.
  defp wear_shield(state, points) do
    use = state.active_use
    shield = Inventory.held(state.inventory, use.hand)
    creative = state.player.game_mode.current == :creative
    {after_shield, broken} = Durability.hurt_and_break(shield, points, creative)
    slot = if use.hand == :main, do: 36 + state.inventory.selected, else: 45
    inventory = state.inventory |> Inventory.put(slot, after_shield) |> Inventory.advance()
    state = CreativeInventory.resync_inventory(%{state | inventory: inventory})

    if broken do
      state
      |> ItemUse.stop_item_use()
      |> sound("minecraft:item.shield.break", 0.8, Float32.round(0.8 + :rand.uniform() * 0.4))
    else
      state
    end
  end

  # `BlocksAttacks.onBlocked`: the block sound at the blocker.
  defp shield_sound(state),
    do:
      sound(
        state,
        "minecraft:item.shield.block",
        1.0,
        Float32.round(0.8 + Float32.round(Float32.round(:rand.uniform()) * 0.4))
      )

  defp sound(state, name, volume, pitch) do
    %{x: x, y: y, z: z} = state.player
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    packet = CombatPackets.sound(name, "player", {x, y, z}, volume, pitch, seed)
    Movement.broadcast_player_packet(state, packet)
    send_packets(state, [packet])
    state
  end

  @doc """
  `knockback` on a player at `velocity` (on the ground or not), resisted by
  the knockback resistance of its `equipment`.
  """
  def knockback_velocity(velocity, on_ground, power, direction, equipment),
    do: Melee.knockback(velocity, on_ground, power, direction, resistance(equipment))

  # The player's knockback resistance with what its `equipment` adds.
  defp resistance(equipment),
    do:
      Attributes.value(
        "minecraft:knockback_resistance",
        Weapons.player_base("minecraft:knockback_resistance"),
        for(
          {slot, stack} <- equipment,
          {"minecraft:knockback_resistance", id, amount, op} <- Weapons.modifiers(stack, slot),
          do: {id, amount, op}
        )
      )

  # Knockback on the session's player: its new velocity reaches its client.
  defp knockback(state, power, direction) do
    motion = state.player.motion

    velocity =
      knockback_velocity(
        motion.velocity,
        motion.on_ground,
        power,
        direction,
        Armor.equipment(state.inventory)
      )

    state = %{state | player: %{state.player | motion: %{motion | velocity: velocity}}}
    Movement.send_velocity(state, velocity)
    state
  end

  defp lift(state, lift) do
    motion = state.player.motion
    resistance = resistance(Armor.equipment(state.inventory))
    {vx, vy, vz} = motion.velocity
    velocity = {vx, vy + lift * max(0.0, 1.0 - resistance), vz}
    state = %{state | player: %{state.player | motion: %{motion | velocity: velocity}}}
    Movement.send_velocity(state, velocity)
    state
  end

  @doc "`dealDefaultKnockback`'s direction: from `position` towards `source` (reversed by knockback)."
  def away(_position, nil), do: {0.0, 0.0}
  def away({x, _, z}, {sx, _, sz}), do: {sx - x, sz - z}

  defp attacker_name(%{type: type}) when is_binary(type) do
    case Valimc.Data.EntityTypes.fetch(type) do
      %{description: name} -> {:compound, %{"translate" => {:string, name}}}
      _ -> nil
    end
  end

  defp attacker_name(_), do: nil
end
