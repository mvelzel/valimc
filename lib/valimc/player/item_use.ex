defmodule Valimc.Player.ItemUse do
  @moduledoc "Held-item use inside the connection: start, ticks, completion effects and equipment publication (VMC-069)."

  alias Valimc.Protocol.{ItemTypes, Packets, PotionContents, UseItem}

  alias Valimc.Player.Vitals

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.Living.{Armor, Effects}

  alias Valimc.Living.FoodItems
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{PlayerList, Equipment, Input, Use}

  def use_item(state, payload) do
    case UseItem.decode(payload) do
      {:ok, request} ->
        if Input.loaded?(state.player.input) do
          send_packets(state, [Packets.ack(request.sequence)])
          # Native requests supply wrapped viewing angles before attempting use.
          player = %{
            state.player
            | yaw: wrap_angle(request.yaw),
              pitch: wrap_angle(request.pitch)
          }

          PlayerList.update(state.connection, player)
          state = %{state | player: player}
          stack = Inventory.held(state.inventory, request.hand)

          # Lily pads and frogspawn place on the water looked at (VMC-029d).
          if (stack && Valimc.Blocks.Placement.on_water?(stack.item_id)) and
               state.active_use == nil,
             do: Valimc.Player.Placement.place_on_water(state, request.hand, request.sequence),
             else: begin_item_use(state, request.hand)
        else
          state
        end

      {:error, _} ->
        reject(state, "Invalid item use request")
    end
  end

  def wrap_angle(value) do
    value = :math.fmod(value, 360.0)

    cond do
      value >= 180.0 -> value - 360.0
      value < -180.0 -> value + 360.0
      true -> value
    end
  end

  def begin_item_use(%{active_use: %Use{}} = state, _), do: state
  def begin_item_use(%{player: %{game_mode: %{current: :spectator}}} = state, _), do: state

  def begin_item_use(state, hand) do
    state = publish_equipment(state)
    stack = Inventory.held(state.inventory, hand)
    props = if stack, do: FoodItems.properties(stack)

    cond do
      Valimc.Player.Buckets.bucket?(stack) ->
        Valimc.Player.Buckets.use(state, hand)

      # Throws, bows and crossbows (VMC-037o).
      Valimc.Player.Projectiles.handles?(stack) ->
        Valimc.Player.Projectiles.use(state, hand, stack)

      # A shield is raised for as long as the client holds use (VMC-037n).
      Valimc.Living.Weapons.blocks_attacks(stack) != nil ->
        state = %{state | active_use: Use.blocking(stack, hand)}
        publish_item_use(state, Use.start_flags(state.player.use_flags, hand))

      true ->
        begin_food_use(state, hand, stack, props)
    end
  end

  defp begin_food_use(state, hand, stack, props) do
    if props && match?({:ok, _}, item_use_effects(stack, props)) &&
         FoodItems.eligible?(props, state.player.food, state.player.abilities) do
      use = Use.new(stack, hand, props)
      state = %{state | active_use: use}

      if use.remaining == 0,
        do: complete_item_use(state, false),
        else: publish_item_use(state, Use.start_flags(state.player.use_flags, hand))
    else
      Valimc.Player.CreativeInventory.resync_inventory(state)
    end
  end

  def item_use_effects(stack, props) do
    cond do
      FoodItems.plain?(props) ->
        {:ok, []}

      props.other_listeners == ["minecraft:potion_contents"] and
          FoodItems.plain?(%{props | other_listeners: []}) ->
        contents =
          case Map.fetch(stack.components, "minecraft:potion_contents") do
            {:ok, value} ->
              value

            :error ->
              bytes = ItemTypes.defaults(stack.item_id).values["minecraft:potion_contents"]
              {value, <<>>} = PotionContents.take(bytes)
              value
          end

        effects = PotionContents.effects(contents)

        if Valimc.Player.Consumption.admitted_effects?(effects),
          do: {:ok, effects},
          else: :unsupported

      true ->
        case Effects.removal_policy(stack, props) do
          {:ok, policy} ->
            {:ok, {:remove, policy}}

          :unsupported ->
            case Effects.food_policy(stack, props) do
              {:ok, callbacks} -> {:ok, {:chance, callbacks}}
              :unsupported -> :unsupported
            end
        end
    end
  end

  def resolve_item_use_effects({:chance, callbacks}) do
    # One unbiased 24-bit native-float draw per group, in this socket owner's RNG.
    # Preflight/cancellation never draw; the accepted outcome shares the meal's save.
    draws = Enum.map(callbacks, fn _ -> (:rand.uniform(16_777_216) - 1) / 16_777_216 end)
    {:ok, effects} = Effects.food_effects(callbacks, draws)
    effects
  end

  def resolve_item_use_effects(effects), do: effects

  def publish_item_use(state, flags) do
    player = %{state.player | use_flags: flags}
    PlayerList.update(state.connection, player)
    state = %{state | player: player}
    # Observers get the flag from the player's tracker (VMC-077i4).
    send_packets(state, [Valimc.Player.Packets.player_use(player)])
    state
  end

  @doc false
  def publish_equipment(state) do
    source = {state.inventory.selected, state.inventory.slots}

    if source == state.equipment_source do
      state
    else
      equipment = Equipment.capture(state.inventory)

      state =
        if Equipment.changes(equipment, state.player.equipment) == [] do
          %{state | equipment_source: source}
        else
          player = %{state.player | equipment: equipment}
          PlayerList.update(state.connection, player)
          %{state | player: player, equipment_source: source}
        end

      attributes = Armor.attributes(Armor.equipment(state.inventory))

      if attributes != state.armor_view and state.phase == :play,
        do:
          send_packets(state, [
            Valimc.Living.Packets.armor_attributes(state.player.entity_id, attributes)
          ])

      %{state | armor_view: attributes} |> Valimc.Player.Attack.publish_speed()
    end
  end

  @doc false
  def stop_item_use(%{active_use: nil} = state), do: state

  def stop_item_use(state),
    do: publish_item_use(%{state | active_use: nil}, Use.stop_flags(state.player.use_flags))

  def tick_item_use(%{life_stage: :alive, active_use: %Use{} = use} = state) do
    state = if use.kind == :crossbow, do: Valimc.Player.Projectiles.charge(state), else: state
    use = state.active_use

    case use && Use.tick(use, Inventory.held(state.inventory, use.hand)) do
      nil -> state
      {:using, next} -> %{state | active_use: next}
      {:finish, %Use{blocking: true}} -> stop_item_use(state)
      {:finish, %Use{kind: kind}} when kind != nil -> stop_item_use(state)
      {:finish, next} -> complete_item_use(%{state | active_use: next}, true)
      {:cancel, _} -> stop_item_use(state)
    end
  end

  def tick_item_use(state), do: state

  def complete_item_use(state, notify) do
    use = state.active_use
    stack = Inventory.held(state.inventory, use.hand)
    props = FoodItems.properties(stack)

    with {:ok, incoming} <- item_use_effects(stack, props) do
      incoming = resolve_item_use_effects(incoming)

      case Valimc.Player.Consumption.plan(
             state.player,
             state.inventory,
             use.hand,
             props,
             incoming
           ) do
        {:ok, transition} ->
          state = %{state | player: transition.player, inventory: transition.inventory}
          state = if transition.death, do: Vitals.dead_state(state), else: state
          PlayerList.update(state.connection, state.player)
          if notify, do: send_packets(state, [Packets.use_item_finished(state.player.entity_id)])

          effect_packets =
            Enum.map(transition.effects, fn
              {:remove, id} ->
                Packets.remove_effect(state.player.entity_id, id)

              {:update, id, rung, new} ->
                Valimc.Living.Packets.update_effect(state.player.entity_id, id, rung, new)
            end)

          send_packets(state, effect_packets)

          for {:self_magic, _} <- transition.damage do
            packet = Packets.self_magic_damage(state.player.entity_id)
            send_packets(state, [packet])
            Valimc.Player.Movement.broadcast_player_packet(state, packet)
          end

          state =
            if transition.death do
              state
              |> stop_item_use()
              |> Valimc.Player.Mining.cancel_mining()
              |> Valimc.Player.Menus.close()
            else
              state
            end

          state =
            state
            |> publish_equipment()
            |> stop_item_use()
            |> Valimc.Player.Movement.publish_movement_speed()
            |> Valimc.Player.Movement.publish_absorption()
            |> Valimc.Player.Movement.publish_jump_boost()

          send_packets(state, [
            Valimc.Player.Packets.health(state.player.living.health, state.player.food),
            Valimc.Player.Packets.player_health(state.player),
            Valimc.Menus.Packets.inventory(state.inventory),
            Packets.cursor(state.inventory.carried)
          ])

          state =
            if transition.death,
              do: state |> Vitals.death_notice(true, transition.death) |> Vitals.continue_life(),
              else: state

          state

        _ ->
          # Patched stackable containers need an explicit conversion outbox before
          # overflowing into the world. Reject the whole meal until that exists.
          state |> stop_item_use() |> Valimc.Player.CreativeInventory.resync_inventory()
      end
    else
      :unsupported ->
        state |> stop_item_use() |> Valimc.Player.CreativeInventory.resync_inventory()
    end
  end
end
