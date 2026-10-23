defmodule Valimc.Blocks.Furnace do
  @moduledoc "Furnace, smoker and blast furnace: an owned cooking entry."
  use Valimc.Blocks.Behaviour
  alias Valimc.Blocks.CookingBlocks

  @impl true
  def block_entity(state), do: CookingBlocks.kind(state)
end
