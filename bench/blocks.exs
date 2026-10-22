defmodule Bench.Blocks do
  @moduledoc """
  Fixture block writes for benchmarks through the fenced owner API
  (VMC-077a): `Valimc.World` has no raw block calls. Load with
  `Code.require_file("blocks.exs", __DIR__)`.
  """
  alias Valimc.World
  alias Valimc.World.Region

  def set({x, _, z} = position, block) do
    {:ok, owner} =
      World.owner(Valimc.Data.Grid.section(:overworld, Valimc.Data.Grid.chunk_key(x, z)))

    {:ok, view} = Region.observe_blocks(owner, [position])
    {:ok, _} = Region.set_blocks(owner, view.fence, %{position => block}, MapSet.new([position]))
    :ok
  end

  def get({x, _, z} = position) do
    {:ok, owner} =
      World.owner(Valimc.Data.Grid.section(:overworld, Valimc.Data.Grid.chunk_key(x, z)))

    {:ok, view} = Region.observe_blocks(owner, [position])
    view.blocks[position]
  end
end
