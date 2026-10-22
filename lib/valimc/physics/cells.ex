defprotocol Valimc.Physics.Cells do
  @moduledoc """
  What the physics kernel reads of a world (VMC-077r): the cells around a
  region, as `{:states, binary}` (supplied `x, y, z, state` records) or
  `{:rows, snapshots, below}` (published chunk rows and the state below the
  build height). `Valimc.World.View` implements it, so physics stays below
  the world.
  """
  def cells(view, region)
end
