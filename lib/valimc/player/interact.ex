defmodule Valimc.Player.Interact do
  @moduledoc """
  `interact` (`handleInteract`, `Player.interactOn`) on a body in reach that
  this group owns (VMC-042a): a name tag with a custom name names a living
  mob and makes it persistent (`NameTagItem.interactLivingEntity`), used up
  unless the player has infinite materials, and the arm swings. Any other
  held item (or none) goes to the owner (VMC-043c,
  `Valimc.Entity.Animals.Interaction`: feeding, milking, shearing, stew,
  dyeing), whose answer says how the held stack changes (used up, filled
  as a bucket fills, or worn as a tool wears), whether the server swings
  the arm, and a sound the others hear of the player's own use. A lead's
  use on a mob or a fence knot (VMC-043c3, `Valimc.Entity.Leashes`) goes to
  the owner the same way.
  """
  alias Valimc.Living.Durability
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Attack, Buckets, CreativeInventory, Input, Movement}
  alias Valimc.Protocol.{CombatPackets, EntityPackets, ItemTypes, PackedVelocity, Wire}
  alias Valimc.World.Region

  @name_tag ItemTypes.id("name_tag")
  # `LivingEntity.breakItem`'s entity events (the hand's item broke).
  @breaks %{main: 47, off: 48}

  def interact(state, payload) do
    {id, rest} = Wire.take_varint(payload)
    {hand, rest} = Wire.take_varint(rest)
    {:ok, _location, rest} = PackedVelocity.take(rest)
    <<sneaking, rest::binary>> = rest
    true = sneaking in 0..1 and rest == <<>>
    hand = if hand == 1, do: :off, else: :main

    with true <- state.life_stage == :alive,
         true <- state.player.game_mode.current != :spectator,
         true <- Input.loaded?(state.player.input),
         {:ok, %{kind: kind} = view, owner} when kind in [:mob, :object] <-
           Attack.target(state, id) do
      stack = Inventory.held(state.inventory, hand)
      sneaking = sneaking == 1

      cond do
        kind == :object and view.type == "minecraft:leash_knot" ->
          knot(state, hand, stack, view, owner, sneaking)

        kind == :object ->
          state

        (name = name_tag(stack)) != nil ->
          name(state, hand, stack, view, owner, name)

        true ->
          use(state, hand, stack, view, owner, sneaking)
      end
    else
      _ -> state
    end
  end

  defp name_tag(%{item_id: @name_tag} = stack) do
    if not MapSet.member?(stack.removed, "minecraft:custom_name"),
      do: stack.components["minecraft:custom_name"]
  end

  defp name_tag(_stack), do: nil

  defp name(state, hand, stack, view, owner, name) do
    case Region.name_entity(owner, view.uuid, name) do
      :ok -> swing(state, hand) |> use_up(hand, stack, 1)
      _ -> state
    end
  end

  defp use(state, hand, stack, view, owner, sneaking) do
    request = Map.put(request(state, stack, sneaking), :hand, hand)

    case Region.interact_entity(owner, view.uuid, request) do
      # A merchant trades (VMC-044b2): its menu opens.
      {:ok, %{merchant: trade} = reply} ->
        state
        |> answer(hand, stack, view, {:ok, Map.delete(reply, :merchant)})
        |> Valimc.Player.Merchant.open(owner, trade)

      reply ->
        answer(state, hand, stack, view, reply)
    end
  end

  # A fence knot (VMC-043c3): the player's mobs move to it or from it.
  defp knot(state, hand, stack, view, owner, sneaking) do
    answer(
      state,
      hand,
      stack,
      view,
      Region.interact_knot(owner, view.uuid, request(state, stack, sneaking))
    )
  end

  # The player as an interaction sees it: its item, infinite materials, and
  # its body as a lead's holder (VMC-043c3).
  defp request(state, stack, sneaking) do
    player = state.player
    pose = Map.get(player, :pose, :standing)
    {:ok, dimensions} = Valimc.Data.PlayerPose.dimensions(pose)

    %{
      item: stack,
      infinite: state.inventory.infinite_materials,
      player: player.uuid,
      sneaking: sneaking,
      holder: %{
        id: player.entity_id,
        x: player.x * 1.0,
        y: player.y * 1.0,
        z: player.z * 1.0,
        width: dimensions["width"] * 1.0,
        height: dimensions["height"] * 1.0
      }
    }
  end

  defp answer(state, hand, stack, view, reply) do
    case reply do
      {:ok, %{hand: change, swing: swing, others: others}} ->
        state = if swing, do: swing(state, hand), else: state
        state = others(state, others, view)
        hand(state, hand, stack, change)

      _ ->
        state
    end
  end

  # A sound of the player's own use the others hear, at the player or the animal.
  defp others(state, nil, _view), do: state

  defp others(state, {sound, source, volume, pitch, at}, view) do
    position =
      case at do
        :player -> {state.player.x, state.player.y, state.player.z}
        :animal -> view.at
      end

    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    packet = CombatPackets.sound(sound, source, position, volume, pitch, seed)
    Movement.broadcast_player_packet(state, packet)
    state
  end

  defp hand(state, _hand, _stack, :keep), do: state
  defp hand(state, hand, stack, {:use, n}), do: use_up(state, hand, stack, n)

  defp hand(state, hand, stack, {:fill, new}),
    do:
      CreativeInventory.resync_inventory(%{
        state
        | inventory: Buckets.filled(state.inventory, hand, stack, new)
      })

  defp hand(state, hand, stack, {:capture, new}) do
    {inventory, left} = Buckets.captured(state.inventory, hand, stack, new)
    {:ok, state} = Valimc.Player.Items.drop(state, inventory, if(left, do: [left], else: []))
    CreativeInventory.resync_inventory(state)
  end

  # `hurtAndBreak`: the tool wears; broken, it goes with its sound and event.
  defp hand(state, hand, stack, {:wear, n}) do
    {after_wear, broken} = Durability.hurt_and_break(stack, n, state.inventory.infinite_materials)
    state = put(state, hand, after_wear)

    if broken do
      %{x: x, y: y, z: z} = state.player
      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

      sound =
        CombatPackets.sound("minecraft:entity.item.break", "player", {x, y, z}, 1.0, 1.0, seed)

      event = EntityPackets.entity_event(state.player.entity_id, @breaks[hand])
      Movement.broadcast_player_packet(state, sound)
      Movement.broadcast_player_packet(state, event)
      Valimc.Protocol.Codec.send_packets(state, [sound, event])
    else
      state
    end
  end

  defp swing(state, hand) do
    action = if hand == :main, do: 0, else: 3
    Movement.broadcast_player_packet(state, EntityPackets.animate(state.player.entity_id, action))
    state
  end

  # `itemStack.shrink(n)`, which a player with infinite materials gets back.
  defp use_up(%{inventory: %{infinite_materials: true}} = state, _hand, _stack, _n), do: state

  defp use_up(state, hand, stack, n) do
    put(state, hand, if(stack.count > n, do: %{stack | count: stack.count - n}))
  end

  defp put(state, hand, stack) do
    slot = if hand == :main, do: 36 + state.inventory.selected, else: 45

    CreativeInventory.resync_inventory(%{
      state
      | inventory: Inventory.put(state.inventory, slot, stack)
    })
  end
end
