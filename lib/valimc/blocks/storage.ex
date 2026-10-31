defmodule Valimc.Blocks.Storage do
  @moduledoc """
  Storage blocks (VMC-032c1): plain item stores with no timers and no joined
  form, each owning one storage entry (`Valimc.World.Containers`) of its
  kind's size. Barrels and shulker boxes (VMC-032c2) hold 27 slots.
  """

  @sizes %{barrel: 27, shulker_box: 27}

  @doc "The storage kinds and their sizes."
  def sizes, do: @sizes

  @doc "The storage kind of a block state (`:barrel`, `:shulker_box`), or nil."
  def kind(state) do
    kind = Valimc.Blocks.block_entity(state)
    if is_map_key(@sizes, kind), do: kind
  end
end
