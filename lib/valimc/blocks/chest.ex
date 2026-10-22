defmodule Valimc.Blocks.Chest do
  @moduledoc "Ordinary chest (`ChestBlock`): single chests own a container."
  use Valimc.Blocks.Behaviour
  use Valimc.Data.Facts, "protocol/chest_states.json"
  alias Valimc.Protocol.ItemStack

  @single MapSet.new(@facts["single_states"])
  @ordinary MapSet.new(@facts["states"], & &1["state"])
  @double for state <- @facts["states"],
              state["part"] != "single",
              into: MapSet.new(),
              do: state["state"]

  @doc "Whether a block state is an ordinary chest, single or half of a double."
  def ordinary?(block), do: MapSet.member?(@ordinary, block)

  @doc "Whether a block state is a single ordinary chest (the ones that own a container)."
  def single?(block), do: MapSet.member?(@single, block)
  def single_states, do: @single

  @doc "The ordinary chest states that are half of a double chest."
  def double_states, do: @double

  @impl true
  def block_entity(state), do: if(single?(state), do: :chest)

  @impl true
  def harvest_drops(state),
    do: if(single?(state), do: {:ok, [ItemStack.new("chest")]}, else: :default)
end
