defmodule Valimc.AI.Shapes do
  @moduledoc """
  Block collision shapes as a mob reads them through its world
  (`Valimc.AI.World`), as `Valimc.Physics.Clip.collider/2` gives them:
  whether a box is free of blocks and the world border
  (`CollisionGetter.noCollision`, VMC-043e's shulkers), and whether a
  block's face is full (`Block.isFaceFull` of its collision shape, what
  `loadedAndEntityCanStandOnFace` asks). A cell that cannot be read stops
  everything (`isLoaded`).
  """
  alias Valimc.AI.World
  alias Valimc.Physics.Clip

  # `Direction` by its 3D value: axis (0 x, 1 y, 2 z) and sign.
  @faces {{1, -1}, {1, 1}, {2, -1}, {2, 1}, {0, -1}, {0, 1}}
  @steps {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}

  @doc "The cell next to `{x, y, z}` across face `face` (3D order)."
  def relative({x, y, z}, face) do
    {dx, dy, dz} = elem(@steps, face)
    {x + dx, y + dy, z + dz}
  end

  @doc "The face opposite `face`."
  def opposite(face), do: Bitwise.bxor(face, 1)

  @doc "The axis of `face`: 0 x, 1 y, 2 z."
  def axis(face), do: elem(elem(@faces, face), 0)

  @doc "A face's unit step `{dx, dy, dz}`."
  def step(face), do: elem(@steps, face)

  @doc """
  The collision boxes of the block at `cell` in world space, or nil where
  the cell cannot be read.
  """
  def boxes(world, {x, y, z} = cell) do
    case World.block(world, cell) do
      nil ->
        nil

      state ->
        {shape, {ox, oy, oz}} = Clip.collider(state, cell)

        for {x0, y0, z0, x1, y1, z1} <- shape.boxes,
            do: {x0 + x + ox, y0 + y + oy, z0 + z + oz, x1 + x + ox, y1 + y + oy, z1 + z + oz}
    end
  end

  @doc """
  Whether `box` meets no block's collision shape and stays inside the
  world border (`noCollision` without entities): false where a cell it
  touches cannot be read.
  """
  def free?(%World{} = world, {x0, y0, z0, x1, y1, z1} = box) do
    inside_border?(world, box) and
      Enum.all?(cells(box), fn cell ->
        case boxes(world, cell) do
          nil -> false
          list -> not Enum.any?(list, &World.intersects?(&1, box))
        end
      end) and x1 > x0 and y1 > y0 and z1 > z0
  end

  @doc "Native findFreePosition over a mob's small local resize volume; unknown cells refuse it."
  def free_position(
        world,
        {x0, y0, z0, x1, y1, z1} = space,
        point,
        {width, height, depth},
        context
      ) do
    search = {x0 - width, y0 - height, z0 - depth, x1 + width, y1 + height, z1 + depth}
    {a0, b0, c0, a1, b1, c1} = search

    cells =
      for x <- (floor(a0) - 1)..(floor(a1) + 1),
          y <- (floor(b0) - 1)..(floor(b1) + 1),
          z <- (floor(c0) - 1)..(floor(c1) + 1),
          do: {x, y, z}

    obstacles =
      Enum.reduce_while(cells, [], fn cell, acc ->
        case resize_boxes(world, cell, context) do
          nil ->
            {:halt, :unknown}

          boxes ->
            kept =
              Enum.filter(boxes, &(World.intersects?(&1, search) and within_border?(world, &1)))

            {:cont, kept ++ acc}
        end
      end)

    if obstacles == :unknown do
      nil
    else
      inflated =
        for {a0, b0, c0, a1, b1, c1} <- obstacles,
            do:
              {a0 - width / 2, b0 - height / 2, c0 - depth / 2, a1 + width / 2, b1 + height / 2,
               c1 + depth / 2}

      Valimc.Physics.FreePosition.closest(space, point, inflated)
    end
  end

  defp resize_boxes(world, cell, context) do
    case World.block(world, cell) do
      nil ->
        nil

      state ->
        case Valimc.Data.BlockFacts.collision(state) do
          {:context, _} -> Valimc.Physics.Kernel.collision_boxes(state, cell, context)
          _ -> boxes(world, cell)
        end
    end
  end

  defp within_border?(%World{border: nil}, _box), do: true

  defp within_border?(%World{border: {min_x, min_z, max_x, max_z}}, {x0, _, z0, x1, _, z1}),
    do: x1 > min_x and x0 < max_x and z1 > min_z and z0 < max_z

  defp inside_border?(%World{border: nil}, _box), do: true

  defp inside_border?(%World{border: {min_x, min_z, max_x, max_z}}, {x0, _, z0, x1, _, z1}),
    do: x0 >= min_x and z0 >= min_z and x1 <= max_x and z1 <= max_z

  # The cells a box's collision search reads (`BlockCollisions`: one cell of
  # margin is enough for full and partial shapes).
  defp cells({x0, y0, z0, x1, y1, z1}) do
    for x <- floor(x0 - 1.0e-7)..floor(x1 + 1.0e-7)//1,
        y <- floor(y0 - 1.0e-7)..floor(y1 + 1.0e-7)//1,
        z <- floor(z0 - 1.0e-7)..floor(z1 + 1.0e-7)//1,
        do: {x, y, z}
  end

  @doc """
  `Block.isFaceFull` of the collision shape at `cell` toward `face` (3D
  order): the shape's slice at that face covers the whole face. False where
  the cell cannot be read.
  """
  def face_full?(world, {x, y, z} = cell, face) do
    case boxes(world, cell) do
      nil ->
        false

      boxes ->
        {axis, sign} = elem(@faces, face)
        origin = {x * 1.0, y * 1.0, z * 1.0}
        # `getFaceShape`: the layer of voxels that holds 1e-7 inside the face.
        plane = if sign > 0, do: 1.0 - 1.0e-7, else: 1.0e-7

        rects =
          for b <- boxes,
              {low, high} = span(b, origin, axis),
              low <= plane and plane <= high,
              do: project(b, origin, axis)

        covered?(rects)
    end
  end

  defp span(b, origin, axis),
    do: {elem(b, axis) - elem(origin, axis), elem(b, axis + 3) - elem(origin, axis)}

  # The box on the face's plane, in the cell's own coordinates.
  defp project(b, origin, axis) do
    [u, v] = Enum.reject([0, 1, 2], &(&1 == axis))
    sub = fn i -> elem(b, i) - elem(origin, rem(i, 3)) end
    {sub.(u), sub.(v), sub.(u + 3), sub.(v + 3)}
  end

  # Whether rectangles `{u0, v0, u1, v1}` cover the unit square.
  defp covered?([]), do: false

  defp covered?(rects) do
    us = rects |> Enum.flat_map(fn {u0, _, u1, _} -> [u0, u1] end) |> grid()
    vs = rects |> Enum.flat_map(fn {_, v0, _, v1} -> [v0, v1] end) |> grid()

    for {ua, ub} <- Enum.zip(us, tl(us)), {va, vb} <- Enum.zip(vs, tl(vs)), reduce: true do
      false ->
        false

      true ->
        {u, v} = {(ua + ub) / 2, (va + vb) / 2}
        Enum.any?(rects, fn {u0, v0, u1, v1} -> u0 <= u and u <= u1 and v0 <= v and v <= v1 end)
    end
  end

  defp grid(points),
    do:
      ([0.0, 1.0] ++ Enum.filter(points, &(&1 > 0.0 and &1 < 1.0))) |> Enum.uniq() |> Enum.sort()
end
