defmodule Valimc.Block.Chest do
  @moduledoc "Ordinary chest (`ChestBlock`): single chests own a container; yaw/water placement."
  use Valimc.Block.Behaviour
  alias Valimc.ChestAccess
  alias Valimc.Physics.ChestPlacement
  alias Valimc.Protocol.ItemStack

  @impl true
  def block_entity(state), do: if(ChestAccess.single?(state), do: :chest)

  @impl true
  def placement(_item, previous, _face, _upper, request),
    do: ChestPlacement.single_state(request[:yaw], previous)

  @impl true
  def harvest_drops(state),
    do: if(ChestAccess.single?(state), do: {:ok, [ItemStack.new("chest")]}, else: :default)
end
