defmodule Valimc.Physics.VoxelOps do
  @moduledoc "Bounded pure voxel operations; no owner/world access."
  import Bitwise
  alias Valimc.Physics.{Box, Shape}
  @epsilon 1.0e-7
  @max_axis 32
  @max_cells 32_768
  @max_boxes 64
  @max_intersection_cells 262_144

  def box(bounds), do: make_box(bounds, 16.0)
  def world_box(bounds), do: make_box(bounds, 60_000_000.0)

  defp make_box({_, _, _, _, _, _} = bounds, bound) do
    unless Enum.all?(Tuple.to_list(bounds), &coordinate?(&1, bound)) and Box.valid?(bounds),
      do: invalid!()

    {x0, y0, z0, x1, y1, z1} = bounds
    ranges = [{x0 * 1.0, x1 * 1.0}, {y0 * 1.0, y1 * 1.0}, {z0 * 1.0, z1 * 1.0}]

    if Enum.any?(ranges, fn {lo, hi} -> hi - lo < @epsilon end) do
      %Shape{}
    else
      resolutions = Enum.map(ranges, &resolution/1)

      if Enum.any?(resolutions, &is_nil/1) do
        %Shape{
          axes: List.to_tuple(ranges),
          sizes: {1, 1, 1},
          bits: <<1>>,
          boxes: [List.to_tuple(Enum.map(ranges, &elem(&1, 0)) ++ Enum.map(ranges, &elem(&1, 1)))]
        }
      else
        sizes = resolutions |> Enum.map(&(1 <<< &1)) |> List.to_tuple()

        axes =
          sizes
          |> Tuple.to_list()
          |> Enum.map(fn n -> for i <- 0..n, do: i / n end)
          |> Enum.map(&List.to_tuple/1)
          |> List.to_tuple()

        spans =
          Enum.zip_with(ranges, Tuple.to_list(sizes), fn {lo, hi}, n ->
            {floor(lo * n + 0.5), floor(hi * n + 0.5)}
          end)
          |> List.to_tuple()

        filled =
          for x <- indices(elem(sizes, 0)),
              y <- indices(elem(sizes, 1)),
              z <- indices(elem(sizes, 2)),
              inside?(x, elem(spans, 0)) and inside?(y, elem(spans, 1)) and
                inside?(z, elem(spans, 2)),
              into: MapSet.new(),
              do: index(sizes, x, y, z)

        to_shape(%{axes: axes, sizes: sizes, filled: filled})
      end
    end
  end

  defp make_box(_, _), do: invalid!()

  def intersects?(%Shape{} = left, %Shape{} = right) do
    validate!(left, 60_000_000.0)
    validate!(right, 60_000_000.0)

    if Shape.empty?(left) or Shape.empty?(right) do
      false
    else
      maps =
        for axis <- 0..2, do: intersection_axis(elem(left.axes, axis), elem(right.axes, axis))

      [nx, ny, nz] = Enum.map(maps, &max(length(&1) - 1, 0))
      if nx * ny * nz > @max_intersection_cells, do: invalid!()
      maps = maps |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

      Enum.any?(indices(nx), fn x ->
        Enum.any?(indices(ny), fn y ->
          Enum.any?(indices(nz), fn z ->
            mapped_full?(left, maps, x, y, z, 1) and mapped_full?(right, maps, x, y, z, 2)
          end)
        end)
      end)
    end
  end

  def intersects?(_, _), do: invalid!()

  @doc "Native FULL support test on one block-local face, including interior slices of moving shapes."
  def face_full?(%Shape{} = shape, direction) when direction in 0..5 do
    validate!(shape)

    if Shape.empty?(shape) do
      false
    else
      {axis, positive} =
        elem({{1, false}, {1, true}, {2, false}, {2, true}, {0, false}, {0, true}}, direction)

      coordinates = elem(shape.axes, axis)

      cube_like =
        tuple_size(coordinates) == 2 and abs(elem(coordinates, 0)) <= @epsilon and
          abs(elem(coordinates, 1) - 1.0) <= @epsilon

      source = grid(shape)

      face =
        if cube_like,
          do: source,
          else: face_slice(source, axis, if(positive, do: 0.9999999, else: 1.0e-7))

      unit = grid(box({0.0, 0.0, 0.0, 1.0, 1.0, 1.0}))
      maps = for a <- 0..2, do: merge_axis(elem(unit.axes, a), elem(face.axes, a))
      sizes = maps |> Enum.map(&(length(&1) - 1)) |> List.to_tuple()
      bound!(sizes)
      maps = maps |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

      not Enum.any?(indices(elem(sizes, 0)), fn x ->
        Enum.any?(indices(elem(sizes, 1)), fn y ->
          Enum.any?(indices(elem(sizes, 2)), fn z ->
            mapped_full?(unit, maps, x, y, z, 1) != mapped_full?(face, maps, x, y, z, 2)
          end)
        end)
      end)
    end
  end

  def face_full?(_, _), do: invalid!()

  defp face_slice(source, axis, value) do
    coordinates = elem(source.axes, axis)
    slice = Enum.count(Tuple.to_list(coordinates), &(&1 <= value)) - 1
    sizes = put_elem(source.sizes, axis, 1)
    axes = put_elem(source.axes, axis, {0.0, 1.0})

    filled =
      for x <- indices(elem(sizes, 0)),
          y <- indices(elem(sizes, 1)),
          z <- indices(elem(sizes, 2)),
          original = put_elem({x, y, z}, axis, slice),
          slice >= 0 and slice < elem(source.sizes, axis) and
            full?(
              source,
              index(source.sizes, elem(original, 0), elem(original, 1), elem(original, 2))
            ),
          into: MapSet.new(),
          do: index(sizes, x, y, z)

    %{axes: axes, sizes: sizes, filled: filled}
  end

  defp intersection_axis(a, b) when a == b,
    do: a |> Tuple.to_list() |> Enum.with_index() |> Enum.map(fn {v, i} -> {v, i, i} end)

  defp intersection_axis(a, b),
    do: merge_intersection(Tuple.to_list(a), Tuple.to_list(b), -1, -1, [])

  defp merge_intersection([], [], _, _, acc), do: Enum.reverse(acc)

  defp merge_intersection(a, b, ia, ib, acc) do
    {v, a, b, ia, ib, skip} =
      case {a, b} do
        {[], [v | tail]} ->
          {v, [], tail, ia, ib + 1, true}

        {[v | tail], []} ->
          {v, tail, [], ia + 1, ib, true}

        {[va | ta], [vb | tb]} ->
          if va < vb + @epsilon,
            do: {va, ta, b, ia + 1, ib, ib < 0},
            else: {vb, a, tb, ia, ib + 1, ia < 0}
      end

    acc =
      if skip do
        acc
      else
        case acc do
          [{previous, _, _} | tail] when previous >= v - @epsilon -> [{previous, ia, ib} | tail]
          _ -> [{v, ia, ib} | acc]
        end
      end

    merge_intersection(a, b, ia, ib, acc)
  end

  def union(%Shape{} = left, %Shape{} = right) do
    validate!(left)
    validate!(right)
    left |> join(right) |> optimize_grid() |> to_shape()
  end

  def union(_, _), do: invalid!()

  def optimize(%Shape{} = shape) do
    validate!(shape)
    shape |> grid() |> optimize_grid() |> to_shape()
  end

  def optimize(_), do: invalid!()

  defp resolution({lo, hi}) do
    if lo < -@epsilon or hi > 1.0 + @epsilon do
      nil
    else
      Enum.find(0..3, fn b ->
        n = 1 <<< b

        abs(lo * n - floor(lo * n + 0.5)) < @epsilon * n and
          abs(hi * n - floor(hi * n + 0.5)) < @epsilon * n
      end)
    end
  end

  defp join(left, right), do: join_grids(grid(left), grid(right))

  defp join_grids(left, right) do
    cond do
      MapSet.size(left.filled) == 0 -> right
      MapSet.size(right.filled) == 0 -> left
      true -> join_nonempty(left, right)
    end
  end

  defp join_nonempty(left, right) do
    maps = for axis <- 0..2, do: merge_axis(elem(left.axes, axis), elem(right.axes, axis))

    axes =
      maps
      |> Enum.map(fn points -> points |> Enum.map(&elem(&1, 0)) |> List.to_tuple() end)
      |> List.to_tuple()

    sizes = axes |> Tuple.to_list() |> Enum.map(&(tuple_size(&1) - 1)) |> List.to_tuple()
    bound!(sizes)
    maps = Enum.map(maps, &List.to_tuple/1) |> List.to_tuple()

    filled =
      for x <- indices(elem(sizes, 0)),
          y <- indices(elem(sizes, 1)),
          z <- indices(elem(sizes, 2)),
          mapped_full?(left, maps, x, y, z, 1) or mapped_full?(right, maps, x, y, z, 2),
          into: MapSet.new(),
          do: index(sizes, x, y, z)

    %{axes: axes, sizes: sizes, filled: filled}
  end

  # Prefer the left coordinate within native epsilon; later equal points update
  # cell membership without changing the retained coordinate.
  defp merge_axis(a, b), do: merge_axis(Tuple.to_list(a), Tuple.to_list(b), -1, -1, [])
  defp merge_axis([], [], _, _, acc), do: Enum.reverse(acc)

  defp merge_axis(a, b, ia, ib, acc) do
    {value, a, b, ia, ib} =
      case {a, b} do
        {[], [v | tail]} ->
          {v, [], tail, ia, ib + 1}

        {[v | tail], []} ->
          {v, tail, [], ia + 1, ib}

        {[va | ta], [vb | tb]} ->
          if va < vb + @epsilon, do: {va, ta, b, ia + 1, ib}, else: {vb, a, tb, ia, ib + 1}
      end

    acc =
      case acc do
        [{previous, _, _} | tail] when previous >= value - @epsilon -> [{previous, ia, ib} | tail]
        _ -> [{value, ia, ib} | acc]
      end

    merge_axis(a, b, ia, ib, acc)
  end

  defp mapped_full?(g, maps, x, y, z, source) do
    x = elem(elem(elem(maps, 0), x), source)
    y = elem(elem(elem(maps, 1), y), source)
    z = elem(elem(elem(maps, 2), z), source)

    x >= 0 and y >= 0 and z >= 0 and x < elem(g.sizes, 0) and y < elem(g.sizes, 1) and
      z < elem(g.sizes, 2) and
      full?(g, index(g.sizes, x, y, z))
  end

  defp optimize_grid(g) do
    g
    |> boxes()
    |> Enum.reduce(grid(%Shape{}), fn bounds, acc ->
      join_grids(acc, grid(box(bounds)))
    end)
  end

  # Greedy Z strips expand across X, then Y. A private residual set prevents
  # overlap and preserves native box order during reconstruction.
  defp boxes(%{filled: filled} = g) do
    {_, result} =
      for y <- indices(elem(g.sizes, 1)),
          x <- indices(elem(g.sizes, 0)),
          z <- indices(elem(g.sizes, 2)),
          reduce: {filled, []} do
        {remaining, acc} ->
          if MapSet.member?(remaining, index(g.sizes, x, y, z)) do
            z1 =
              grow(z + 1, elem(g.sizes, 2), fn endz ->
                MapSet.member?(remaining, index(g.sizes, x, y, endz))
              end)

            x1 =
              grow(x + 1, elem(g.sizes, 0), fn endx ->
                strip?(remaining, g.sizes, endx, y, z, z1)
              end)

            y1 =
              grow(y + 1, elem(g.sizes, 1), fn endy ->
                Enum.all?(x..(x1 - 1), &strip?(remaining, g.sizes, &1, endy, z, z1))
              end)

            remaining =
              Enum.reduce(x..(x1 - 1), remaining, fn cx, r ->
                Enum.reduce(y..(y1 - 1), r, fn cy, r ->
                  Enum.reduce(z..(z1 - 1), r, fn cz, r ->
                    MapSet.delete(r, index(g.sizes, cx, cy, cz))
                  end)
                end)
              end)

            {ax, ay, az} = g.axes

            bounds =
              {elem(ax, x), elem(ay, y), elem(az, z), elem(ax, x1), elem(ay, y1), elem(az, z1)}

            if length(acc) >= @max_boxes, do: invalid!()
            {remaining, [bounds | acc]}
          else
            {remaining, acc}
          end
      end

    Enum.reverse(result)
  end

  defp grow(value, limit, _predicate) when value >= limit, do: value

  defp grow(value, limit, predicate),
    do: if(predicate.(value), do: grow(value + 1, limit, predicate), else: value)

  defp strip?(filled, sizes, x, y, z0, z1),
    do: Enum.all?(z0..(z1 - 1), &MapSet.member?(filled, index(sizes, x, y, &1)))

  defp grid(%Shape{} = shape) do
    {nx, ny, nz} = shape.sizes

    filled =
      for x <- indices(nx),
          y <- indices(ny),
          z <- indices(nz),
          full?(shape, index(shape.sizes, x, y, z)),
          into: MapSet.new(),
          do: index(shape.sizes, x, y, z)

    %{axes: shape.axes, sizes: shape.sizes, filled: filled}
  end

  defp full?(%Shape{} = shape, i),
    do: (:binary.at(shape.bits, div(i, 8)) &&& 1 <<< rem(i, 8)) != 0

  defp full?(%{filled: filled}, i), do: MapSet.member?(filled, i)

  defp to_shape(%{filled: filled} = g) do
    if MapSet.size(filled) == 0 do
      %Shape{}
    else
      bound!(g.sizes)
      {nx, ny, nz} = g.sizes

      bytes =
        for byte <- indices(div(nx * ny * nz + 7, 8)), into: <<>> do
          value =
            Enum.reduce(0..7, 0, fn bit, acc ->
              if MapSet.member?(filled, byte * 8 + bit), do: acc ||| 1 <<< bit, else: acc
            end)

          <<value>>
        end

      full =
        g.axes == {{0.0, 1.0}, {0.0, 1.0}, {0.0, 1.0}} and g.sizes == {1, 1, 1} and bytes == <<1>>

      %Shape{axes: g.axes, sizes: g.sizes, bits: bytes, boxes: boxes(g), full_block: full}
    end
  end

  defp validate!(shape, bound \\ 16.0) do
    bound!(shape.sizes)

    unless is_tuple(shape.axes) and tuple_size(shape.axes) == 3 and is_binary(shape.bits) and
             is_list(shape.boxes),
           do: invalid!()

    {nx, ny, nz} = shape.sizes
    unless byte_size(shape.bits) == div(nx * ny * nz + 7, 8), do: invalid!()

    for axis <- 0..2 do
      coordinates = elem(shape.axes, axis)

      unless is_tuple(coordinates) and tuple_size(coordinates) == elem(shape.sizes, axis) + 1,
        do: invalid!()

      unless Enum.all?(Tuple.to_list(coordinates), &coordinate?(&1, bound)), do: invalid!()
    end

    boxes = Enum.take(shape.boxes, @max_boxes + 1)
    if length(boxes) > @max_boxes, do: invalid!()

    for box <- boxes do
      unless is_tuple(box) and tuple_size(box) == 6 and
               Enum.all?(Tuple.to_list(box), &coordinate?(&1, bound)),
             do: invalid!()
    end

    facts = %{
      "axes" => shape.axes |> Tuple.to_list() |> Enum.map(&Tuple.to_list/1),
      "sizes" => Tuple.to_list(shape.sizes),
      "bits" => Base.encode16(shape.bits, case: :lower),
      "boxes" => Enum.map(boxes, &Tuple.to_list/1),
      "full_block" => shape.full_block
    }

    if bound == 16.0, do: Shape.from_facts!(facts), else: Shape.from_world_facts!(facts)

    :ok
  rescue
    _ -> invalid!()
  end

  defp bound!({nx, ny, nz}) do
    unless is_integer(nx) and is_integer(ny) and is_integer(nz) and
             nx >= 0 and ny >= 0 and nz >= 0 and nx <= @max_axis and ny <= @max_axis and
             nz <= @max_axis and
             nx * ny * nz <= @max_cells,
           do: invalid!()
  end

  defp bound!(_), do: invalid!()

  defp coordinate?(n, bound), do: is_number(n) and n >= -bound and n <= bound
  defp indices(0), do: []
  defp indices(n), do: 0..(n - 1)
  defp inside?(value, {lo, hi}), do: value >= lo and value < hi
  defp index({_nx, ny, nz}, x, y, z), do: (x * ny + y) * nz + z
  defp invalid!, do: raise(ArgumentError, "invalid or unbounded voxel operation")
end
