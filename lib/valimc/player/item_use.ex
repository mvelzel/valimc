defmodule Valimc.Player.ItemUse do
  @moduledoc "Held-item use inside the connection: start, ticks, completion effects and equipment publication (VMC-069)."

  alias Valimc.Protocol.{
    EffectTypes,
    ItemTypes,
    Packets,
    PotionContents,
    UseItem
  }

  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    ConsumableRemoval,
    FoodItems,
    Inventory,
    Players,
    PlayerEquipment,
    PlayerInput,
    PlayerSnapshot,
    PlayerStore,
    PlayerUse
  }

  alias Valimc.World.{}
  @fire_resistance EffectTypes.id("fire_resistance")
  @resistance EffectTypes.id("resistance")
  @absorption EffectTypes.id("absorption")
  @periodic_effects Enum.sort(Enum.map(~w(regeneration hunger poison wither), &EffectTypes.id/1))
  @instant_effects Enum.map(~w(instant_health instant_damage saturation), &EffectTypes.id/1)
  @live_effects [@fire_resistance, @resistance, @absorption, EffectTypes.id("water_breathing")] ++
                  Enum.map(
                    ~w(speed slowness nausea jump_boost slow_falling levitation),
                    &EffectTypes.id/1
                  ) ++
                  @periodic_effects

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def use_item(state, payload) do
    case UseItem.decode(payload) do
      {:ok, request} ->
        if PlayerInput.loaded?(state.player.input) do
          send_packets(state, [Packets.ack(request.sequence)])
          # Native requests supply wrapped viewing angles before attempting use.
          player = %{
            state.player
            | yaw: wrap_angle(request.yaw),
              pitch: wrap_angle(request.pitch)
          }

          Players.update(self(), player)
          begin_item_use(%{state | player: player}, request.hand)
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

  def begin_item_use(state, _) when inventory_pending(state),
    do: Valimc.Player.CreativeInventory.resync_inventory(state)

  def begin_item_use(%{active_use: %PlayerUse{}} = state, _), do: state
  def begin_item_use(%{player: %{game_mode: %{current: :spectator}}} = state, _), do: state

  def begin_item_use(state, hand) do
    state = publish_equipment(state)
    stack = Inventory.held(state.inventory, hand)
    props = if stack, do: FoodItems.properties(stack)

    if props && match?({:ok, _}, item_use_effects(stack, props)) &&
         FoodItems.eligible?(props, state.player.food, state.player.abilities) do
      use = PlayerUse.new(stack, hand, props)
      state = %{state | active_use: use}

      if use.remaining == 0,
        do: complete_item_use(state, false),
        else: publish_item_use(state, PlayerUse.start_flags(state.player.use_flags, hand))
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

        if Enum.all?(effects, fn {id, _} -> id in @live_effects or id in @instant_effects end) and
             Valimc.PlayerConsumption.admitted_effects?(effects),
           do: {:ok, effects},
           else: :unsupported

      true ->
        case ConsumableRemoval.policy(stack, props) do
          {:ok, policy} ->
            {:ok, {:remove, policy}}

          :unsupported ->
            with {:ok, callbacks} <- Valimc.StockFoodEffects.policy(stack, props),
                 true <-
                   Enum.all?(callbacks, fn callback ->
                     Enum.all?(callback.effects, fn {id, _} -> id in @live_effects end)
                   end) do
              {:ok, {:chance, callbacks}}
            else
              _ -> :unsupported
            end
        end
    end
  end

  def resolve_item_use_effects({:chance, callbacks}) do
    # One unbiased 24-bit native-float draw per group, in this socket owner's RNG.
    # Preflight/cancellation never draw; the accepted outcome shares the meal's save.
    draws = Enum.map(callbacks, fn _ -> (:rand.uniform(16_777_216) - 1) / 16_777_216 end)
    {:ok, effects} = Valimc.StockFoodEffects.resolve(callbacks, draws)
    effects
  end

  def resolve_item_use_effects(effects), do: effects

  def publish_item_use(state, flags) do
    player = %{state.player | use_flags: flags}
    Players.update(self(), player)
    state = %{state | player: player}
    packet = Packets.player_use(player)
    send_packets(state, [packet])

    for pid <- Players.nearby(state.regions),
        pid != self(),
        do: Valimc.Connection.deliver(pid, {:player_use_packet, self(), player.entity_id, packet})

    state
  end

  @doc false
  def publish_equipment(state) do
    source = {state.inventory.selected, state.inventory.slots}

    if source == state.equipment_source do
      state
    else
      equipment = PlayerEquipment.capture(state.inventory)

      state =
        if PlayerEquipment.changes(equipment, state.player.equipment) == [] do
          %{state | equipment_source: source}
        else
          player = %{state.player | equipment: equipment}
          Players.update(self(), player)
          %{state | player: player, equipment_source: source}
        end

      attributes = Valimc.PlayerArmor.attributes(state.inventory)

      if attributes != state.armor_view and state.phase == :play,
        do: send_packets(state, [Packets.armor_attributes(state.player, attributes)])

      %{state | armor_view: attributes}
    end
  end

  @doc false
  def stop_item_use(%{active_use: nil} = state), do: state

  def stop_item_use(state),
    do: publish_item_use(%{state | active_use: nil}, PlayerUse.stop_flags(state.player.use_flags))

  def tick_item_use(%{life_stage: :alive, active_use: %PlayerUse{} = use} = state) do
    case PlayerUse.tick(use, Inventory.held(state.inventory, use.hand)) do
      {:using, next} -> %{state | active_use: next}
      {:finish, next} -> complete_item_use(%{state | active_use: next}, true)
      {:cancel, _} -> stop_item_use(state)
    end
  end

  def tick_item_use(state), do: state

  def complete_item_use(state, _) when inventory_pending(state) or state.save_ref != nil,
    do: state

  def complete_item_use(state, notify) do
    use = state.active_use
    stack = Inventory.held(state.inventory, use.hand)
    props = FoodItems.properties(stack)

    with {:ok, incoming} <- item_use_effects(stack, props) do
      incoming = resolve_item_use_effects(incoming)

      case Valimc.PlayerConsumption.plan(state.player, state.inventory, use.hand, props, incoming) do
        {:ok, transition} ->
          # Plan health and all callbacks without I/O, then queue one immutable
          # checkpoint before any socket write or death lifecycle can run.
          ref = make_ref()

          state = %{
            state
            | player: transition.player,
              inventory: transition.inventory,
              save_ref: ref,
              use_save: ref
          }

          state = if transition.death, do: Vitals.dead_state(state), else: state

          PlayerStore.checkpoint(
            state.player_store,
            state.store_fence,
            PlayerSnapshot.capture(state.player, state.inventory),
            ref
          )

          Process.send_after(self(), {:save_deadline, ref}, 5000)
          Players.update(self(), state.player)
          if notify, do: send_packets(state, [Packets.use_item_finished(state.player.entity_id)])

          effect_packets =
            Enum.map(transition.effects, fn
              {:remove, id} ->
                Packets.remove_effect(state.player.entity_id, id)

              {:update, id, rung, new} ->
                Packets.update_effect(state.player.entity_id, id, rung, new)
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
              |> Valimc.Player.Movement.cancel_pose_job()
              |> Valimc.Player.Movement.cancel_motion_job()
              |> stop_item_use()
              |> Valimc.Player.Mining.cancel_mining()
              |> Valimc.Player.Menus.begin_table_close()
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
            Packets.health(state.player.health, state.player.food),
            Packets.player_health(state.player),
            Packets.inventory(state.inventory),
            Packets.cursor(state.inventory.carried)
          ])

          state =
            if transition.death,
              do: Vitals.death_notice(state, true, transition.death),
              else: state

          send(self(), :drain)
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
