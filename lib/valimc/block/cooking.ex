defmodule Valimc.Block.Cooking do
  @moduledoc "Furnace, smoker and blast furnace: an owned cooking entry and facing placement."
  use Valimc.Block.Behaviour
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack

  @impl true
  def block_entity(state), do: CookingBlocks.kind(state)

  @impl true
  def placement(item, _previous, _face, _upper, request),
    do: CookingBlocks.placement(CookingBlocks.kind_for_item(item), request[:yaw])

  @impl true
  def harvest_drops(state) do
    case CookingBlocks.kind(state) do
      nil -> :default
      kind -> {:ok, [ItemStack.new(Atom.to_string(kind))]}
    end
  end
end
