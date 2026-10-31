defmodule Valimc.Player.EnderChest do
  @moduledoc """
  A player's ender chest slots (VMC-032c3, `PlayerEnderChestContainer`): 27
  slots that live with the player as `ender_items` (occupied slots by index,
  saved as vanilla's `EnderItems`), so every ender chest shows the same items
  to their owner and each player sees only their own.

  The menu is a three-row chest menu over these slots
  (`ChestMenu.threeRows`). A click runs the shared click engine on the slots
  and the inventory together inside the session, so both change in the same
  player state and reach the player's next frame together
  (`Valimc.Player.Storage`): a crash keeps both or neither. The chest's owner
  only checks that the chest is still there and in reach, and counts its
  viewers for the lid.
  """
  alias Valimc.Menus.{Click, Menu}

  @size 27

  @doc "The player's ender slots as the menu shows them: a 27-tuple."
  def slots(player) do
    items = Map.get(player, :ender_items, %{})
    List.to_tuple(for slot <- 0..(@size - 1), do: Map.get(items, slot))
  end

  @doc "The occupied slots of a 27-tuple, as the player keeps them."
  def items(slots) when is_tuple(slots) and tuple_size(slots) == @size do
    for {stack, slot} <- slots |> Tuple.to_list() |> Enum.with_index(),
        stack != nil,
        into: %{},
        do: {slot, stack}
  end

  @doc """
  A click in the ender chest menu: `{:ok, player, inventory, drops}` with the
  player's slots and inventory after it and the stacks it throws out, or an
  error with nothing changed.
  """
  def click(player, inventory, %{action: action, slot: slot, button: button}) do
    case Click.plan(Menu.storage(:ender_chest), slots(player), inventory, action, slot, button) do
      {:ok, slots, inventory, drops} ->
        {:ok, Map.put(player, :ender_items, items(slots)), inventory, drops}

      error ->
        error
    end
  end
end
