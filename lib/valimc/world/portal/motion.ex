defmodule Valimc.World.Portal.Motion do
  @moduledoc """
  A teleport's arrival pose (VMC-026c), as vanilla's
  `PositionMoveRotation.calculateAbsolute` turns a transition and its relative
  flags into one: each relative coordinate, rotation or velocity component
  adds to the traveller's own; with `:rotate_delta` the traveller's velocity
  first turns by the rotation's change (`Vec3.xRot`, then `yRot`, with
  `Mth`'s sine table). Rotations are floats, as vanilla's are.

  A pose is `%{position: {x, y, z}, delta: {x, y, z}, yaw: f, pitch: f}`;
  relatives are `:x`, `:y`, `:z`, `:y_rot`, `:x_rot`, `:delta_x`, `:delta_y`,
  `:delta_z` and `:rotate_delta`.
  """
  alias Valimc.Data.Float32

  # `Relative.DELTA` and `Relative.ROTATION`.
  @delta [:delta_x, :delta_y, :delta_z, :rotate_delta]
  @rotation [:x_rot, :y_rot]

  @doc "The relatives of a nether portal's or a gateway's transition (`DELTA ∪ ROTATION`)."
  def portal, do: @delta ++ @rotation

  @doc "The relatives of an end portal into the End (`DELTA ∪ {X_ROT}`)."
  def into_end, do: @delta ++ [:x_rot]

  @doc "The arrival of `source` through a transition `change` with `relatives`."
  def absolute(source, change, relatives) do
    relative = &(&1 in relatives)
    {sx, sy, sz} = source.position
    {cx, cy, cz} = change.position

    position = {
      if(relative.(:x), do: sx, else: 0.0) + cx,
      if(relative.(:y), do: sy, else: 0.0) + cy,
      if(relative.(:z), do: sz, else: 0.0) + cz
    }

    yaw =
      Float32.round(
        if(relative.(:y_rot), do: Float32.round(source.yaw), else: 0.0) +
          Float32.round(change.yaw)
      )

    pitch =
      (if(relative.(:x_rot), do: Float32.round(source.pitch), else: 0.0) +
         Float32.round(change.pitch))
      |> Float32.round()
      |> max(-90.0)
      |> min(90.0)

    turned =
      if relative.(:rotate_delta) do
        source.delta
        |> x_rot(radians(Float32.round(Float32.round(source.pitch) - pitch)))
        |> y_rot(radians(Float32.round(Float32.round(source.yaw) - yaw)))
      else
        source.delta
      end

    {tx, ty, tz} = turned
    {dx, dy, dz} = change.delta

    delta = {
      if(relative.(:delta_x), do: tx + dx, else: dx),
      if(relative.(:delta_y), do: ty + dy, else: dy),
      if(relative.(:delta_z), do: tz + dz, else: dz)
    }

    %{position: position, delta: delta, yaw: yaw, pitch: pitch}
  end

  # `(float) Math.toRadians(degrees)`.
  defp radians(degrees), do: Float32.round(degrees * 0.017453292519943295)

  defp x_rot({x, y, z}, radians) do
    {cos, sin} = {cos(radians), sin(radians)}
    {x, y * cos + z * sin, z * cos - y * sin}
  end

  defp y_rot({x, y, z}, radians) do
    {cos, sin} = {cos(radians), sin(radians)}
    {x * cos + z * sin, y, z * cos - x * sin}
  end

  defdelegate sin(value), to: Valimc.Data.Mth
  defdelegate cos(value), to: Valimc.Data.Mth
end
