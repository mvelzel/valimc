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
