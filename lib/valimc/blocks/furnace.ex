defmodule Valimc.Blocks.Furnace do
  @moduledoc "Furnace, smoker and blast furnace: an owned cooking entry."
  use Valimc.Blocks.Behaviour
  alias Valimc.Blocks.CookingBlocks
  alias Valimc.Protocol.ItemStack

  @impl true
  def block_entity(state), do: CookingBlocks.kind(state)

  @impl true
  def harvest_drops(state) do
    case CookingBlocks.kind(state) do
      nil -> :default
      kind -> {:ok, [ItemStack.new(Atom.to_string(kind))]}
    end
  end
end
