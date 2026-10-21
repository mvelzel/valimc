defmodule Valimc.Block.NetherPortal do
  @moduledoc """
  Nether portal blocks (`NetherPortalBlock`, VMC-026b2). A portal whose frame
  or opening stops being a complete portal shape after a neighbour changes
  goes out: vanilla's `updateShape` turns its blocks to air in the same update
  cascade; here the first block to notice schedules a tick and then removes
  the whole connected portal at once (one block's tick later, as support
  breaks wait a tick). A shape reaching beyond the region (a read of `nil`)
  never breaks a portal.
  """
  use Valimc.Block.Behaviour
  alias Valimc.Portal.{Blocks, Shape}

  @air Valimc.Registry.Blocks.default_state("air")
  # The most cells one portal has (21 × 21), with room for touching portals.
  @limit 4096

  @impl true
  def shape_update(position, state, read, _random) do
    if broken?(position, state, read), do: [{:schedule, position, state, 1, 0}], else: []
  end

  @impl true
  def scheduled_tick(position, state, read, _random) do
    if broken?(position, state, read),
      do: for(cell <- connected(position, state, read), do: {:set, cell, @air}),
      else: []
  end

  defp broken?(position, state, read) do
    known = fn pos ->
      case read.(pos) do
        nil -> throw(:outside)
        block -> block
      end
    end

    {min_y, _height} = Valimc.Dimension.bounds()
    not Shape.complete?(Shape.find_any(known, position, Blocks.portal_axis(state), min_y))
  catch
    :outside -> false
  end

  # The portal blocks of the same axis joined to `position` in the portal's plane.
  defp connected(position, state, read) do
    {dx, _, dz} = Shape.right(Blocks.portal_axis(state))
    steps = [{dx, 0, dz}, {-dx, 0, -dz}, {0, 1, 0}, {0, -1, 0}]
    flood([position], MapSet.new([position]), steps, state, read)
  end

  defp flood([], seen, _steps, _state, _read), do: MapSet.to_list(seen)

  defp flood([pos | rest], seen, steps, state, read) do
    next =
      for step <- steps,
          cell = Shape.offset(pos, step, 1),
          not MapSet.member?(seen, cell),
          read.(cell) == state,
          do: cell

    seen = Enum.reduce(next, seen, &MapSet.put(&2, &1))

    if MapSet.size(seen) > @limit,
      do: MapSet.to_list(seen),
      else: flood(next ++ rest, seen, steps, state, read)
  end
end
