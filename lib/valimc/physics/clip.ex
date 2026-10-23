defmodule Valimc.Physics.Clip do
  @moduledoc """
  Vanilla's `BlockGetter.clip` with outline shapes (VMC-031a): a ray from a
  point to a point through block outlines and, when the fluid mode picks
  them, fluid shapes, as an item's `getPlayerPOVHitResult` casts it (buckets
  pick only sources). Cells are visited as `traverseBlocks` does; each cell's
  outline (`priv/physics/outlines.json`, `FluidOracle outlines`) and fluid are
  clipped as `VoxelShape.clip` and `AABB.clip` do, and the nearer hit wins,
  the block's on a tie. An interaction shape's face override
  (`clipWithInteractionOverride`: cauldrons, composters, hoppers) is not
  applied.

  Hits are `%{miss: false, position: {x, y, z}, face: d, location: {x, y, z},
  inside: boolean}` (faces in `Direction` order: down, up, north, south,
  west, east); a miss has the end point, the face toward the start and the
  cell holding the end.
  """
  use Valimc.Data.Facts, "physics/outlines.json"
  import Bitwise
  alias Valimc.Data.{BlockFacts, Float32}

  shape = fn %{"axes" => axes, "sizes" => sizes, "bits" => bits, "boxes" => boxes} ->
    %{
      axes:
        axes
        |> Enum.map(fn a -> a |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end)
        |> List.to_tuple(),
      sizes: List.to_tuple(sizes),
      bits: Base.decode16!(bits, case: :lower),
      boxes: Enum.map(boxes, fn b -> b |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end)
    }
  end

  @shapes @facts["palette"] |> Enum.map(shape) |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  @offsets Map.new(@facts["offsets"], fn [state, kind, h, v] ->
             {state, {kind, h * 1.0, v * 1.0}}
           end)

  @doc """
  The hit of a ray from `from` to `to` (`{x, y, z}` floats), `fluid` `:none`,
  `:source_only` or `:any` (a fluid's shape at its own height), reading cells with `read` (position => state; nil reads as
  air), against block outlines or, with `:collider`, collision shapes
  (`ClipContext.Block.COLLIDER`, as a mob's line of sight casts it).
  """
  def clip(from, to, fluid, read, shapes \\ :outline) do
    shape = if shapes == :collider, do: &collider/2, else: &outline/2

    case traverse(from, to, nil, fn position, nil ->
           state = read.(position) || 0

           case hit_cell(from, to, position, state, fluid, shape) do
             nil -> {:cont, nil}
             hit -> {:hit, hit}
           end
         end) do
      {:hit, hit} -> hit
      {:miss, nil} -> miss(from, to)
    end
  end

  @doc "The cells `clip/4` visits, in order, when nothing stops it (to read them first)."
  def cells(from, to) do
    {:miss, cells} = traverse(from, to, [], fn position, acc -> {:cont, [position | acc]} end)
    Enum.reverse(cells)
  end

  # `BlockGetter.traverseBlocks`: `visit.(cell, acc)` answers `{:hit, hit}` or
  # `{:cont, acc}`.
  defp traverse({fx, fy, fz} = from, {tx, ty, tz} = to, acc, visit) do
    if from == to do
      {:miss, acc}
    else
      lerp = fn delta, a, b -> a + delta * (b - a) end
      {tox, toy, toz} = {lerp.(-1.0e-7, tx, fx), lerp.(-1.0e-7, ty, fy), lerp.(-1.0e-7, tz, fz)}

      {fromx, fromy, fromz} =
        {lerp.(-1.0e-7, fx, tx), lerp.(-1.0e-7, fy, ty), lerp.(-1.0e-7, fz, tz)}

      cell = {floor(fromx), floor(fromy), floor(fromz)}

      case visit.(cell, acc) do
        {:cont, acc} ->
          {dx, dy, dz} = {tox - fromx, toy - fromy, toz - fromz}
          {sx, sy, sz} = {sign(dx), sign(dy), sign(dz)}
          delta = fn s, d -> if s == 0, do: :max, else: s / d end
          {tdx, tdy, tdz} = {delta.(sx, dx), delta.(sy, dy), delta.(sz, dz)}

          start = fn td, s, f ->
            if td == :max, do: :max, else: td * if(s > 0, do: 1.0 - frac(f), else: frac(f))
          end

          t = {start.(tdx, sx, fromx), start.(tdy, sy, fromy), start.(tdz, sz, fromz)}
          walk(cell, t, {tdx, tdy, tdz}, {sx, sy, sz}, acc, visit)

        hit ->
          hit
      end
    end
  end

  defp walk({x, y, z}, {tx, ty, tz}, {dx, dy, dz} = td, {sx, sy, sz} = s, acc, visit) do
    if le(tx, 1.0) or le(ty, 1.0) or le(tz, 1.0) do
      {cell, t} =
        cond do
          lt(tx, ty) and lt(tx, tz) -> {{x + sx, y, z}, {add(tx, dx), ty, tz}}
          lt(tx, ty) -> {{x, y, z + sz}, {tx, ty, add(tz, dz)}}
          lt(ty, tz) -> {{x, y + sy, z}, {tx, add(ty, dy), tz}}
          true -> {{x, y, z + sz}, {tx, ty, add(tz, dz)}}
        end

      case visit.(cell, acc) do
        {:cont, acc} -> walk(cell, t, td, s, acc, visit)
        hit -> hit
      end
    else
      {:miss, acc}
    end
  end

  # `Double.MAX_VALUE` stands for an axis the ray does not move along.
  defp le(:max, _), do: false
  defp le(a, b), do: a <= b
  defp lt(:max, _), do: false
  defp lt(_, :max), do: true
  defp lt(a, b), do: a < b
  defp add(:max, _), do: :max
  defp add(a, b), do: a + b

  defp sign(v) when v > 0, do: 1
  defp sign(v) when v < 0, do: -1
  defp sign(_), do: 0

  defp frac(v), do: v - Float.floor(v)

  defp miss({fx, fy, fz}, {tx, ty, tz} = to) do
    %{
      miss: true,
      position: {floor(tx), floor(ty), floor(tz)},
      face: nearest(fx - tx, fy - ty, fz - tz),
      location: to,
      inside: false
    }
  end

  # One cell: its outline's hit and its fluid's, the nearer (the block's on a tie).
  defp hit_cell(from, to, position, state, fluid, shape) do
    block = shape_clip(shape.(state, position), from, to, position)
    liquid = fluid_clip(fluid, state, position, from, to)
    distance = fn hit -> if hit, do: distance_sq(from, hit.location), else: :max end

    case {block, liquid} do
      {nil, nil} -> nil
      {block, nil} -> block
      {nil, liquid} -> liquid
      _ -> if distance.(block) <= distance.(liquid), do: block, else: liquid
    end
  end

  defp distance_sq({ax, ay, az}, {bx, by, bz}) do
    {dx, dy, dz} = {bx - ax, by - ay, bz - az}
    dx * dx + dy * dy + dz * dz
  end

  # `ClipContext.getFluidShape`: a source's box up to its own height. Vanilla
  # caches a fluid state's shape with the height of the first cell it was
  # asked at (`FlowingFluid.shapes`); a source under the same fluid would read
  # as a full block only when that came first, so its own height stands.
  defp fluid_clip(:none, _, _, _, _), do: nil

  defp fluid_clip(mode, state, position, from, to) do
    fluid = BlockFacts.fluid(state)

    if fluid.kind != :empty and (mode == :any or fluid.source) do
      height = fluid.height

      box = %{
        axes: {{0.0, 1.0}, {0.0, height}, {0.0, 1.0}},
        sizes: {1, 1, 1},
        bits: <<1>>,
        boxes: [{0.0, 0.0, 0.0, 1.0, height, 1.0}]
      }

      shape_clip({box, {0.0, 0.0, 0.0}}, from, to, position)
    end
  end

  @empty %{axes: {{0.0}, {0.0}, {0.0}}, sizes: {0, 0, 0}, bits: <<>>, boxes: []}
  @full %{
    axes: {{0.0, 1.0}, {0.0, 1.0}, {0.0, 1.0}},
    sizes: {1, 1, 1},
    bits: <<1>>,
    boxes: [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
  }

  @doc """
  A state's collision shape at `position` for a mob's ray: its geometry and
  offset. Shapes that depend on the colliding entity or a block entity read
  as vanilla gives a mob standing beside them: scaffolding, powder snow and
  moving pistons as empty, shulker boxes as closed.
  """
  def collider(state, position) do
    case BlockFacts.collision(state) do
      {:fixed, shape} ->
        {shape, {0.0, 0.0, 0.0}}

      {:offset, shape} ->
        {shape, elem(outline(state, position), 1)}

      {:context, name} ->
        {if(String.ends_with?(name, "shulker_box"), do: @full, else: @empty), {0.0, 0.0, 0.0}}
    end
  end

  @doc "A state's outline shape at `position`: its geometry and offset."
  def outline(state, {x, _, z}) do
    shape = elem(@shapes, :binary.decode_unsigned(:binary.part(@states, 2 * state, 2)))

    case @offsets do
      %{^state => {kind, h, v}} -> {shape, offset(kind, h, v, x, z)}
      _ -> {shape, {0.0, 0.0, 0.0}}
    end
  end

  # `BlockBehaviour.Properties.offsetType`'s offsets from `Mth.getSeed(x, 0, z)`.
  defp offset(kind, h, v, x, z) do
    seed = bxor(wrap32(x * 3_129_871), z * 116_129_781)
    seed = wrap64(wrap64(seed * seed * 42_317_861) + seed * 11) >>> 16
    part = fn n -> Float32.round(band(n, 15) / 15.0) end
    clamp = fn value -> value |> max(-h) |> min(h) end
    dx = clamp.((part.(seed) - 0.5) * 0.5)
    dz = clamp.((part.(seed >>> 8) - 0.5) * 0.5)
    dy = if kind == 2, do: (part.(seed >>> 4) - 1.0) * v, else: 0.0
    {dx, dy, dz}
  end

  defp wrap32(v) do
    <<w::32-signed>> = <<v::32>>
    w
  end

  defp wrap64(v) do
    <<w::64-signed>> = <<v::64>>
    w
  end

  # `VoxelShape.clip`: a start point just inside a filled cell hits at once,
  # facing back along the ray; else the boxes' nearest face (`AABB.clip`).
  defp shape_clip({%{sizes: {nx, ny, nz}} = shape, offset}, from, to, position) do
    if nx * ny * nz == 0 do
      nil
    else
      {fx, fy, fz} = from
      {tx, ty, tz} = to
      {dx, dy, dz} = {tx - fx, ty - fy, tz - fz}

      if dx * dx + dy * dy + dz * dz < 1.0e-7 do
        nil
      else
        test = {fx + dx * 0.001, fy + dy * 0.001, fz + dz * 0.001}
        {px, py, pz} = position
        {ox, oy, oz} = offset
        {tx0, ty0, tz0} = test

        indexes = {
          find_index(shape, 0, tx0 - px, ox),
          find_index(shape, 1, ty0 - py, oy),
          find_index(shape, 2, tz0 - pz, oz)
        }

        if full_wide?(shape, indexes) do
          %{
            miss: false,
            position: position,
            face: Bitwise.bxor(nearest(dx, dy, dz), 1),
            location: test,
            inside: true
          }
        else
          boxes =
            for {x0, y0, z0, x1, y1, z1} <- shape.boxes,
                do:
                  {x0 + ox + px, y0 + oy + py, z0 + oz + pz, x1 + ox + px, y1 + oy + py,
                   z1 + oz + pz}

          aabb_clip(boxes, from, {dx, dy, dz}, position)
        end
      end
    end
  end

  # `VoxelShape.findIndex`: coordinates up to `value`, less one.
  defp find_index(shape, axis, value, offset) do
    coords = elem(shape.axes, axis)
    count = tuple_size(coords)
    search(coords, offset, value, 0, count) - 1
  end

  defp search(coords, offset, value, low, high) when low < high do
    mid = div(low + high, 2)

    if value < elem(coords, mid) + offset,
      do: search(coords, offset, value, low, mid),
      else: search(coords, offset, value, mid + 1, high)
  end

  defp search(_, _, _, low, _), do: low

  defp full_wide?(%{sizes: {nx, ny, nz}, bits: bits}, {x, y, z}) do
    if x < 0 or y < 0 or z < 0 or x >= nx or y >= ny or z >= nz do
      false
    else
      i = (x * ny + y) * nz + z
      band(:binary.at(bits, div(i, 8)) >>> rem(i, 8), 1) == 1
    end
  end

  # `AABB.clip`: the smallest positive scale at which the ray enters a face.
  defp aabb_clip(boxes, {fx, fy, fz}, {dx, dy, dz}, position) do
    {scale, face} =
      Enum.reduce(boxes, {1.0, nil}, fn {x0, y0, z0, x1, y1, z1}, acc ->
        acc
        |> clip_axis(dx, dy, dz, x0, x1, y0, y1, z0, z1, fx, fy, fz, {4, 5})
        |> clip_axis(dy, dz, dx, y0, y1, z0, z1, x0, x1, fy, fz, fx, {0, 1})
        |> clip_axis(dz, dx, dy, z0, z1, x0, x1, y0, y1, fz, fx, fy, {2, 3})
      end)

    if face do
      %{
        miss: false,
        position: position,
        face: face,
        location: {fx + scale * dx, fy + scale * dy, fz + scale * dz},
        inside: false
      }
    end
  end

  defp clip_axis(
         acc,
         da,
         db,
         dc,
         min_a,
         max_a,
         min_b,
         max_b,
         min_c,
         max_c,
         fa,
         fb,
         fc,
         {low, high}
       ) do
    cond do
      da > 1.0e-7 ->
        clip_point(acc, da, db, dc, min_a, min_b, max_b, min_c, max_c, low, fa, fb, fc)

      da < -1.0e-7 ->
        clip_point(acc, da, db, dc, max_a, min_b, max_b, min_c, max_c, high, fa, fb, fc)

      true ->
        acc
    end
  end

  defp clip_point(
         {scale, face},
         da,
         db,
         dc,
         point,
         min_b,
         max_b,
         min_c,
         max_c,
         new_face,
         fa,
         fb,
         fc
       ) do
    s = (point - fa) / da
    pb = fb + s * db
    pc = fc + s * dc

    if 0.0 < s and s < scale and min_b - 1.0e-7 < pb and pb < max_b + 1.0e-7 and
         min_c - 1.0e-7 < pc and pc < max_c + 1.0e-7,
       do: {s, new_face},
       else: {scale, face}
  end

  @doc """
  `Direction.getApproximateNearest`: the face whose normal best matches the
  vector (as floats), north for none.
  """
  def nearest(dx, dy, dz) do
    {dx, dy, dz} = {Float32.round(dx), Float32.round(dy), Float32.round(dz)}

    [-dy, dy, -dz, dz, -dx, dx]
    |> Enum.with_index()
    |> Enum.reduce({2, 1.401298464324817e-45}, fn {dot, d}, {best, highest} ->
      if dot > highest, do: {d, dot}, else: {best, highest}
    end)
    |> elem(0)
  end

  @doc """
  `Entity.calculateViewVector(pitch, yaw)`: the look direction.
  """
  def view_vector(pitch, yaw) do
    radians = Float32.round(:math.pi() / 180.0)
    x_rot = Float32.round(Float32.round(pitch) * radians)
    y_rot = Float32.round(-Float32.round(yaw) * radians)
    {y_cos, y_sin} = {mth_cos(y_rot), mth_sin(y_rot)}
    {x_cos, x_sin} = {mth_cos(x_rot), mth_sin(x_rot)}
    {Float32.round(y_sin * x_cos), -x_sin, Float32.round(y_cos * x_cos)}
  end

  @doc "`{Mth.sin(v), Mth.cos(v)}` (a lead's attachment points turn by them, VMC-043c3)."
  def sin_cos(v), do: {mth_sin(v), mth_cos(v)}

  # `Mth.sin` and `Mth.cos`: a 65,536-entry table of float sines, indexed in
  # double arithmetic.
  @scale 10430.378350470453
  defp mth_sin(v), do: sine(trunc(v * @scale))
  defp mth_cos(v), do: sine(trunc(v * @scale + 16384.0))
  defp sine(i), do: Float32.round(:math.sin(band(i, 65535) / @scale))
end
