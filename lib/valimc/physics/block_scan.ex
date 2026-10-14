defmodule Valimc.Physics.BlockScan do
  @moduledoc "Bounded native block candidates; callers obtain fenced states and resolve geometry separately."
  alias Valimc.Physics.Box
  @epsilon 1.0e-7
  @max_cells 512
  @path Path.expand("../../../priv/physics/collision_shapes.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @state_count @facts["state_count"]
  @large MapSet.new(@facts["large_collision_states"])
  @moving MapSet.new(@facts["piston"]["moving"])
  unless MapSet.size(@large) == length(@facts["large_collision_states"]) and
           Enum.all?(@large, &(is_integer(&1) and &1 >= 0 and &1 < @state_count)),
         do: raise("Invalid protruding collision state catalog")

  def plan(box) do
    if Box.valid?(box) do
      {x0, y0, z0, x1, y1, z1} = box
      lo = {floor(x0 - @epsilon) - 1, floor(y0 - @epsilon) - 1, floor(z0 - @epsilon) - 1}
      hi = {floor(x1 + @epsilon) + 1, floor(y1 + @epsilon) + 1, floor(z1 + @epsilon) + 1}
      {a, b, c} = lo
      {x, y, z} = hi
      volume = (x - a + 1) * (y - b + 1) * (z - c + 1)

      if volume > @max_cells do
        {:error, :block_scan_limit}
      else
        positions =
          for cz <- c..z,
              cy <- b..y,
              cx <- a..x,
              type = boundary(cx, a, x) + boundary(cy, b, y) + boundary(cz, c, z),
              type != 3,
              do: {{cx, cy, cz}, type}

        {:ok, positions}
      end
    else
      {:error, :invalid_box}
    end
  end

  def eligible(_id, 3), do: {:ok, false}

  def eligible(id, type) when is_integer(id) and id >= 0 and id < @state_count and type in 0..2 do
    {:ok,
     type == 0 or (type == 1 and MapSet.member?(@large, id)) or
       (type == 2 and MapSet.member?(@moving, id))}
  end

  def eligible(id, type)
      when type in 0..2 and (not is_integer(id) or id < 0 or id >= @state_count),
      do: {:error, :unknown_block_state}

  def eligible(_, _), do: {:error, :invalid_boundary_type}
  defp boundary(value, lo, hi), do: if(value == lo or value == hi, do: 1, else: 0)
end
