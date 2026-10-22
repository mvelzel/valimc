defmodule Valimc.Commands.Parser.Coordinates do
  @moduledoc """
  Vanilla coordinate arguments (VMC-053): world (`1`, `~1`) and local (`^1`)
  coordinates for `vec3`, `block_pos`, `vec2` and `rotation`, with vanilla's
  centring of integer `vec3` components and errors.
  """
  alias Valimc.Text.{Error, Reader}

  # {:world, [{relative, value}, ...]} or {:local, left, up, forwards}

  def vec3(reader, center \\ true) do
    if Reader.at?(reader, ?^), do: local(reader), else: world(reader, :double, center, 3)
  end

  def block_pos(reader) do
    if Reader.at?(reader, ?^), do: local(reader), else: world(reader, :int, false, 3)
  end

  def vec2(reader, center \\ true) do
    world(reader, :double, center, 2, "argument.pos2d.incomplete")
  end

  @doc "`column_pos`: two integer (or `~`) coordinates, x then z."
  def column_pos(reader) do
    start = reader.cursor
    unless Reader.can_read?(reader), do: Error.fail_at!("argument.pos2d.incomplete", [], reader)
    {x, reader} = coordinate(reader, :int, false)

    if Reader.at?(reader, ?\s) do
      {z, reader} = coordinate(Reader.skip(reader), :int, false)
      {{:world, [x, {true, 0.0}, z]}, reader}
    else
      Error.fail_at!("argument.pos2d.incomplete", [], Reader.set_cursor(reader, start))
    end
  end

  def rotation(reader) do
    start = reader.cursor

    unless Reader.can_read?(reader),
      do: Error.fail_at!("argument.rotation.incomplete", [], reader)

    {y, reader} = coordinate(reader, :double, false)

    if Reader.at?(reader, ?\s) do
      {x, reader} = coordinate(Reader.skip(reader), :double, false)
      {{:world, [x, y, {true, 0.0}]}, reader}
    else
      Error.fail_at!("argument.rotation.incomplete", [], Reader.set_cursor(reader, start))
    end
  end

  defp world(reader, kind, center, count, incomplete \\ "argument.pos3d.incomplete") do
    start = reader.cursor

    {values, reader} =
      Enum.reduce(1..count, {[], reader}, fn index, {acc, reader} ->
        reader =
          cond do
            index == 1 -> reader
            Reader.at?(reader, ?\s) -> Reader.skip(reader)
            true -> Error.fail_at!(incomplete, [], Reader.set_cursor(reader, start))
          end

        # y is never centred; in two dimensions both components are horizontal.
        centred = center and not (count == 3 and index == 2)
        {value, reader} = coordinate(reader, kind, centred)
        {acc ++ [value], reader}
      end)

    {{:world, values}, reader}
  end

  defp coordinate(reader, kind, center) do
    if Reader.at?(reader, ?^), do: Error.fail_at!("argument.pos.mixed", [], reader)

    unless Reader.can_read?(reader),
      do:
        Error.fail_at!(
          if(kind == :int, do: "argument.pos.missing.int", else: "argument.pos.missing.double"),
          [],
          reader
        )

    {relative, reader} =
      if Reader.peek(reader) == ?~, do: {true, Reader.skip(reader)}, else: {false, reader}

    start = reader.cursor

    {value, reader} =
      cond do
        not (Reader.can_read?(reader) and Reader.peek(reader) != ?\s) -> {0.0, reader}
        kind == :int and not relative -> Reader.read_int(reader)
        true -> Reader.read_double(reader)
      end

    number = Reader.slice(reader, start, reader.cursor)

    value =
      cond do
        relative and number == "" ->
          0.0

        kind == :double and center and not relative and not String.contains?(number, ".") ->
          add(value, 0.5)

        true ->
          value
      end

    {{relative, to_double(value)}, reader}
  end

  defp add(value, delta) when is_float(value), do: value + delta
  defp add(value, _delta), do: value

  defp to_double(value) when is_integer(value), do: value * 1.0
  defp to_double(value), do: value

  defp local(reader) do
    start = reader.cursor
    {left, reader} = local_double(reader, start)

    unless Reader.at?(reader, ?\s),
      do: Error.fail_at!("argument.pos3d.incomplete", [], Reader.set_cursor(reader, start))

    {up, reader} = local_double(Reader.skip(reader), start)

    unless Reader.at?(reader, ?\s),
      do: Error.fail_at!("argument.pos3d.incomplete", [], Reader.set_cursor(reader, start))

    {forwards, reader} = local_double(Reader.skip(reader), start)
    {{:local, left, up, forwards}, reader}
  end

  defp local_double(reader, start) do
    cond do
      not Reader.can_read?(reader) ->
        Error.fail_at!("argument.pos.missing.double", [], reader)

      Reader.peek(reader) != ?^ ->
        Error.fail_at!("argument.pos.mixed", [], Reader.set_cursor(reader, start))

      true ->
        reader = Reader.skip(reader)

        if Reader.can_read?(reader) and Reader.peek(reader) != ?\s,
          do: Reader.read_double(reader) |> then(fn {v, r} -> {to_double(v), r} end),
          else: {0.0, reader}
    end
  end

  # ---- resolution ----

  @doc "The position for a source at `{x, y, z}` facing `{yaw, pitch}` (anchor at its feet)."
  def position({:world, [x, y, z]}, {sx, sy, sz}, _rotation),
    do: {get(x, sx), get(y, sy), get(z, sz)}

  def position({:local, left, up, forwards}, {sx, sy, sz}, {yaw, pitch}) do
    rad = :math.pi() / 180.0
    y_cos = f32(:math.cos((yaw + 90.0) * rad))
    y_sin = f32(:math.sin((yaw + 90.0) * rad))
    x_cos = f32(:math.cos(-pitch * rad))
    x_sin = f32(:math.sin(-pitch * rad))
    x_cos_up = f32(:math.cos((-pitch + 90.0) * rad))
    x_sin_up = f32(:math.sin((-pitch + 90.0) * rad))
    fwd = {y_cos * x_cos, x_sin, y_sin * x_cos}
    upv = {y_cos * x_cos_up, x_sin_up, y_sin * x_cos_up}
    {lx, ly, lz} = cross(fwd, upv) |> scale(-1.0)
    {fx, fy, fz} = fwd
    {ux, uy, uz} = upv

    {sx + (fx * forwards + ux * up + lx * left), sy + (fy * forwards + uy * up + ly * left),
     sz + (fz * forwards + uz * up + lz * left)}
  end

  defp f32(value), do: Valimc.Text.Reader.to_float32(value)

  defp cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}

  defp scale({x, y, z}, f), do: {x * f, y * f, z * f}

  @doc """
  `getRotation` as `{yaw, pitch}`: a rotation argument stores pitch as its x and
  yaw as its y coordinate; local coordinates rotate to zero.
  """
  def rotation_of({:world, [x, y | _]}, {yaw, pitch}), do: {f32(get(y, yaw)), f32(get(x, pitch))}
  def rotation_of({:local, _, _, _}, _), do: {0.0, 0.0}

  @doc "`getBlockPos`: the floored position."
  def block({:world, _} = coordinates, origin, rotation),
    do: coordinates |> position(origin, rotation) |> floor3()

  def block(coordinates, origin, rotation),
    do: coordinates |> position(origin, rotation) |> floor3()

  defp floor3({x, y, z}), do: {floor(x), floor(y), floor(z)}

  defp get({true, value}, origin), do: value + origin
  defp get({false, value}, _origin), do: value

  def relative?({:world, components}, index), do: elem(Enum.at(components, index), 0)
  def relative?({:local, _, _, _}, _index), do: true
end
