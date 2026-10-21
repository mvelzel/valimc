defmodule Valimc.Portal.Shape do
  @moduledoc """
  Nether portal frames (VMC-026b2), as vanilla's `PortalShape` finds them: an
  opening 2 to 21 blocks wide and 3 to 21 high along the X or Z axis, framed
  by `#nether_portal_frame` blocks (corners are not needed), empty inside
  (air, fire or portal blocks).

  `read` returns the state at a position. All functions are pure.
  """
  alias Valimc.Portal.Blocks

  defstruct [:axis, :right, :bottom_left, portal_blocks: 0, width: 0, height: 0]

  @doc "The direction a portal's width runs along `axis` (vanilla's `rightDir`)."
  def right(:x), do: {-1, 0, 0}
  def right(:z), do: {0, 0, 1}

  @doc """
  An empty portal shape at `pos` (`findEmptyPortalShape`): along `preferred`,
  else the other axis; `{:ok, shape}` or `:none`.
  """
  def find_empty(read, pos, preferred, min_y),
    do: find(read, pos, preferred, min_y, &(valid?(&1) and &1.portal_blocks == 0))

  @doc "A shape at `pos` satisfying `test`, preferring `preferred` (`findPortalShape`)."
  def find(read, pos, preferred, min_y, test) do
    first = find_any(read, pos, preferred, min_y)

    if test.(first) do
      {:ok, first}
    else
      other = find_any(read, pos, other(preferred), min_y)
      if test.(other), do: {:ok, other}, else: :none
    end
  end

  @doc "The shape at `pos` along `axis`, valid or not (`findAnyShape`)."
  def find_any(read, pos, axis, min_y) do
    right = right(axis)
    shape = %__MODULE__{axis: axis, right: right, bottom_left: pos}

    case bottom_left(read, right, pos, min_y) do
      nil ->
        shape

      bottom_left ->
        shape = %{shape | bottom_left: bottom_left}

        case width(read, bottom_left, right) do
          0 ->
            shape

          width ->
            {height, blocks} = height(read, bottom_left, right, width)
            %{shape | width: width, height: height, portal_blocks: blocks}
        end
    end
  end

  def valid?(%__MODULE__{width: w, height: h}), do: w in 2..21 and h in 3..21

  def complete?(%__MODULE__{} = shape),
    do: valid?(shape) and shape.portal_blocks == shape.width * shape.height

  @doc "The opening's positions (`createPortalBlocks`, `BlockPos.betweenClosed` order)."
  def positions(%__MODULE__{bottom_left: bottom_left, right: right} = shape) do
    {x0, y0, z0} = bottom_left

    {x1, y1, z1} =
      offset(offset(bottom_left, {0, 1, 0}, shape.height - 1), right, shape.width - 1)

    for z <- min(z0, z1)..max(z0, z1),
        y <- min(y0, y1)..max(y0, y1),
        x <- min(x0, x1)..max(x0, x1),
        do: {x, y, z}
  end

  defp other(:x), do: :z
  defp other(:z), do: :x

  defp bottom_left(read, right, {x, y, z}, min_y) do
    floor = max(min_y, y - 21)
    {x, y, z} = descend(read, {x, y, z}, floor)
    left = negate(right)
    edge = edge_distance(read, {x, y, z}, left) - 1
    if edge < 0, do: nil, else: offset({x, y, z}, left, edge)
  end

  defp descend(read, {x, y, z} = pos, floor) do
    if y > floor and empty?(read.({x, y - 1, z})),
      do: descend(read, {x, y - 1, z}, floor),
      else: pos
  end

  defp width(read, bottom_left, right) do
    width = edge_distance(read, bottom_left, right)
    if width in 2..21, do: width, else: 0
  end

  # `getDistanceUntilEdgeAboveFrame`: empty cells over frame blocks up to a frame.
  defp edge_distance(read, pos, direction) do
    Enum.reduce_while(0..21, 0, fn width, _ ->
      {x, y, z} = at = offset(pos, direction, width)
      state = read.(at)

      cond do
        not empty?(state) -> {:halt, if(Blocks.frame?(state), do: width, else: 0)}
        not Blocks.frame?(read.({x, y - 1, z})) -> {:halt, 0}
        true -> {:cont, 0}
      end
    end)
  end

  defp height(read, bottom_left, right, width) do
    {height, blocks} = until_top(read, bottom_left, right, width)

    if height in 3..21 and top_frame?(read, bottom_left, right, width, height),
      do: {height, blocks},
      else: {0, blocks}
  end

  defp top_frame?(read, bottom_left, right, width, height) do
    top = offset(bottom_left, {0, 1, 0}, height)
    Enum.all?(0..(width - 1), &Blocks.frame?(read.(offset(top, right, &1))))
  end

  # `getDistanceUntilTop`: rows framed on both sides and empty inside, with
  # the portal blocks met on the way.
  defp until_top(read, bottom_left, right, width) do
    Enum.reduce_while(0..20, {21, 0}, fn height, {_, blocks} ->
      row = offset(bottom_left, {0, 1, 0}, height)

      if not Blocks.frame?(read.(offset(row, right, -1))) or
           not Blocks.frame?(read.(offset(row, right, width))) do
        {:halt, {height, blocks}}
      else
        result =
          Enum.reduce_while(0..(width - 1), blocks, fn i, blocks ->
            state = read.(offset(row, right, i))

            cond do
              not empty?(state) -> {:halt, {:stop, blocks}}
              Blocks.portal?(state) -> {:cont, blocks + 1}
              true -> {:cont, blocks}
            end
          end)

        case result do
          {:stop, blocks} -> {:halt, {height, blocks}}
          blocks -> {:cont, {21, blocks}}
        end
      end
    end)
  end

  defp empty?(state), do: Blocks.air?(state) or Blocks.fire?(state) or Blocks.portal?(state)

  def offset({x, y, z}, {dx, dy, dz}, n), do: {x + dx * n, y + dy * n, z + dz * n}
  defp negate({x, y, z}), do: {-x, -y, -z}
end
