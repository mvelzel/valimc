defmodule Valimc.Living.Explosions do
  @moduledoc """
  What an explosion does to an entity it reaches (VMC-050a), as vanilla's
  `ServerExplosion.hurtEntities` and the default `ExplosionDamageCalculator`
  decide: entities within twice the radius (a box of that half-size plus one
  around the centre first) take damage by distance and exposure (the share of
  their box that sees the centre, `Physics.Kernel.exposure/3`) and are pushed
  away from the centre. A player's damage then scales with the difficulty
  (`Player.hurtServer` for a source that scales). Pure: owners apply it.
  """
  alias Valimc.Data.Float32

  @doc """
  The box whose entities an explosion of `radius` at `center` considers
  (`hurtEntities`' whole-block bounds), as `{x0, y0, z0, x1, y1, z1}`.
  """
  def reach(radius, {x, y, z}) do
    double = Float32.round(radius * 2.0)
    lo = fn v -> floor(v - double - 1.0) * 1.0 end
    hi = fn v -> floor(v + double + 1.0) * 1.0 end
    {lo.(x), lo.(y), lo.(z), hi.(x), hi.(y), hi.(z)}
  end

  @doc """
  The entity's distance from `center` in units of twice the radius, or nil
  when it is past them (`dist > 1`) and the explosion leaves it alone.
  """
  def distance(radius, center, position) do
    distance = :math.sqrt(squared(position, center)) / Float32.round(radius * 2.0)
    if distance > 1.0, do: nil, else: distance
  end

  @doc """
  The default calculator's damage (`getEntityDamageAmount`) to an entity at
  `position` that sees `seen` of the centre: a float.
  """
  def damage(radius, center, position, seen) do
    double = Float32.round(radius * 2.0)
    distance = :math.sqrt(squared(position, center)) / double
    power = (1.0 - distance) * seen
    Float32.round((power * power + power) / 2.0 * 7.0 * double + 1.0)
  end

  @doc """
  The push an entity takes: away from `center` toward `origin` (its eye, or
  a primed TNT's feet), `(1 - distance) * seen * (1 - resistance)` long, with
  `resistance` its explosion knockback resistance attribute.
  """
  def knockback(center, origin, distance, seen, resistance \\ 0.0) do
    {dx, dy, dz} = sub(origin, center)
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)
    power = (1.0 - distance) * seen * (1.0 - resistance)

    # `Vec3.normalize` leaves a vector shorter than 1.0E-5 at zero.
    if length < 1.0e-5,
      do: {0.0, 0.0, 0.0},
      else: {dx / length * power, dy / length * power, dz / length * power}
  end

  @doc """
  A player's damage from a source that scales with the difficulty (0
  peaceful, 1 easy, 2 normal, 3 hard): none in peaceful, half plus one (at
  most the damage) in easy, half again in hard.
  """
  def scale(amount, 0), do: amount * 0.0
  def scale(amount, 1), do: Float32.round(min(Float32.round(amount / 2.0 + 1.0), amount))
  def scale(amount, 2), do: amount
  def scale(amount, 3), do: Float32.round(Float32.round(amount * 3.0) / 2.0)

  defp squared({x, y, z}, {cx, cy, cz}),
    do: (x - cx) * (x - cx) + (y - cy) * (y - cy) + (z - cz) * (z - cz)

  defp sub({x, y, z}, {cx, cy, cz}), do: {x - cx, y - cy, z - cz}
end
