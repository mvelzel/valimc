defmodule Valimc.Blocks.EnderChest do
  @moduledoc """
  Ender chests (`EnderChestBlock`, VMC-032c3). The block holds no items: its
  block entity saves nothing (a plain block entity,
  `Valimc.Blocks.BlockEntityTypes.plain?/1`), and its use opens the user's
  own 27 ender slots, which live with the player (`Valimc.Player.EnderChest`).

  Its owner still counts the viewers (`ContainerOpenersCounter`): the first
  one opens the lid (block event 1) with `block.ender_chest.open` at the
  centre, the last to leave closes it. A redstone conductor on it keeps it
  shut, as on a chest, but a sitting cat does not.
  """
  alias Valimc.Data.Blocks

  @states Blocks.states("ender_chest")
  @block Blocks.block_id(@states.first)

  @doc "Whether a block state is an ender chest."
  def ender_chest?(state), do: is_integer(state) and state in @states

  @doc """
  The owner's view of an ender chest's menu: the block holds nothing, so its
  revision never moves; the slots are the viewer's own.
  """
  def view, do: %{kind: :ender_chest, revision: 1}

  @doc "The lid's block event for the first opener (`open?`) or the last to leave."
  def lid_event(position, open?) when is_boolean(open?),
    do: Valimc.Protocol.Packets.block_event(position, 1, if(open?, do: 1, else: 0), @block)
end
