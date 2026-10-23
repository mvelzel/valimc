defmodule Valimc.Player.Interact do
  @moduledoc """
  `interact` (`handleInteract`, `Player.interactOn`) on a body in reach that
  this group owns (VMC-042a): a name tag with a custom name names a living
  mob and makes it persistent (`NameTagItem.interactLivingEntity`), used up
  unless the player has infinite materials, and the arm swings. Other
  interactions (a mob's own, leads, buckets, feeding) are their families'.
  """
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Attack, CreativeInventory, Input, Movement}
  alias Valimc.Protocol.{EntityPackets, ItemTypes, PackedVelocity, Wire}
  alias Valimc.World.Region

  @name_tag ItemTypes.id("name_tag")

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
         {:ok, %{kind: :mob} = view, owner} <- Attack.target(state, id),
         %{item_id: @name_tag} = stack <- Inventory.held(state.inventory, hand),
         name when name != nil <- custom_name(stack),
         :ok <- Region.name_entity(owner, view.uuid, name) do
      swing(state, hand) |> use_up(hand, stack)
    else
      _ -> state
    end
  end

  defp custom_name(stack) do
    if not MapSet.member?(stack.removed, "minecraft:custom_name"),
      do: stack.components["minecraft:custom_name"]
  end

  defp swing(state, hand) do
    action = if hand == :main, do: 0, else: 3
    Movement.broadcast_player_packet(state, EntityPackets.animate(state.player.entity_id, action))
    state
  end

  # `itemStack.shrink(1)`, which a player with infinite materials gets back.
  defp use_up(%{inventory: %{infinite_materials: true}} = state, _hand, _stack), do: state

  defp use_up(state, hand, stack) do
    slot = if hand == :main, do: 36 + state.inventory.selected, else: 45
    left = if stack.count > 1, do: %{stack | count: stack.count - 1}

    CreativeInventory.resync_inventory(%{
      state
      | inventory: Inventory.put(state.inventory, slot, left)
    })
  end
end
