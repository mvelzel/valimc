defmodule Valimc.Portal.Contact do
  @moduledoc """
  The portal a moving box touched (VMC-026b2, VMC-026c): the first portal
  block whose inside shape the box met along its movement since the last tick,
  sampled at most half a block apart (an approximation of vanilla's ordered
  block walk, `Entity.checkInsideBlocks`). Players read published snapshots;
  region owners read their own blocks.
  """
  alias Valimc.Registry.BlockFacts
  alias Valimc.Portal.Blocks

  @nether [Blocks.portal(:x), Blocks.portal(:z)]
  @end_portal Valimc.Registry.Blocks.default_state("end_portal")
  @end_gateway Valimc.Registry.Blocks.default_state("end_gateway")
  @deflate 1.0e-5

  @doc "The portal kind of a block state, or nil."
  def kind(state) when state in @nether, do: :nether_portal
  def kind(@end_portal), do: :end_portal
  def kind(@end_gateway), do: :end_gateway
  def kind(_state), do: nil

  @doc """
  `{kind, cell}` for the first portal the box (`box_at.(point)`, as
  `{min_x, min_y, min_z, max_x, max_y, max_z}`) met moving from `from` to
  `to`, or nil. `read.(cells)` gives the states of cells as a map; missing
  cells hold no portal.
  """
  def touched(box_at, from, to, read) do
    cells =
      for point <- path(from, to),
          box = box_at.(point),
          cell <- cells(box),
          uniq: true,
          do: {cell, box}

    states = read.(Enum.map(cells, &elem(&1, 0)))

    Enum.find_value(cells, fn {cell, box} ->
      state = Map.get(states, cell)

      with kind when kind != nil <- state && kind(state),
           true <- inside?(state, cell, box),
           do: {kind, cell},
           else: (_ -> nil)
    end)
  end

  @doc "An entity box of `{width, height}` standing at `{x, y, z}`."
  def box({width, height}, {x, y, z}),
    do: {x - width / 2, y, z - width / 2, x + width / 2, y + height, z + width / 2}

  # Points along a movement, at most half a block apart (16 at most).
  defp path({x0, y0, z0} = from, {x1, y1, z1} = to) do
    distance = :math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2 + (z1 - z0) ** 2)
    steps = distance |> Kernel.*(2) |> ceil() |> max(1) |> min(16)

    if from == to,
      do: [to],
      else:
        for(
          i <- 1..steps,
          t = i / steps,
          do: {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, z0 + (z1 - z0) * t}
        )
  end

  defp cells({min_x, min_y, min_z, max_x, max_y, max_z}) do
    for x <- floor(min_x + @deflate)..floor(max_x - @deflate),
        y <- floor(min_y + @deflate)..floor(max_y - @deflate),
        z <- floor(min_z + @deflate)..floor(max_z - @deflate),
        do: {x, y, z}
  end

  defp inside?(state, {x, y, z}, {min_x, min_y, min_z, max_x, max_y, max_z}) do
    case BlockFacts.inside(state).shape do
      :full ->
        true

      boxes when is_list(boxes) ->
        Enum.any?(boxes, fn {a, b, c, d, e, f} ->
          min_x + @deflate < x + d and max_x - @deflate > x + a and min_y + @deflate < y + e and
            max_y - @deflate > y + b and min_z + @deflate < z + f and max_z - @deflate > z + c
        end)

      _ ->
        false
    end
  end
end
