defmodule Valimc.PlayerMotion do
  @moduledoc "Player-owned accepted movement observations; ground flags are client reports."
  import Bitwise

  defstruct fall_distance: 0.0,
            velocity: {0.0, 0.0, 0.0},
            physical_ground: false,
            settled: false,
            swimming: false,
            # Moves since the last tick, `{from, to, axis}` (at most 100, VMC-077l2).
            paths: [],
            stuck_multiplier: {0.0, 0.0, 0.0},
            known_movement: {0.0, 0.0, 0.0},
            on_ground: false,
            horizontal_collision: false,
            received: false

  def valid_distance?(distance),
    do: is_float(distance) and distance >= 0.0 and distance <= 60_000_000.0

  def distance(player), do: Map.get(player, :motion, %__MODULE__{}).fall_distance

  @doc "Native fall accumulation, before upward-motion or flight resets."
  def fall_step(distance, dy, ground, water)
      when is_number(distance) and distance >= 0 and distance <= 60_000_000 and
             is_number(dy) and abs(dy) <= 60_000_000 and is_boolean(ground) and
             is_boolean(water) do
    # Native fallDistance is double, but each downward delta is cast to float.
    <<rounded::float-32>> = <<dy::float-32>>
    distance = if dy < 0 and not water, do: distance - rounded, else: distance * 1.0
    landed = if ground and distance > 0, do: distance
    {if(ground, do: 0.0, else: distance), landed}
  end

  def accept(%__MODULE__{} = motion, {dx, dy, dz} = movement, flags, flying)
      when is_number(dx) and is_number(dy) and is_number(dz) and is_integer(flags) and
             flags in 0..255 and is_boolean(flying) do
    ground = (flags &&& 1) != 0
    {distance, _landed} = fall_step(motion.fall_distance, dy, ground, false)

    %{
      motion
      | fall_distance: if(flying or dy > 0, do: 0.0, else: distance),
        known_movement: movement,
        on_ground: ground,
        horizontal_collision: (flags &&& 2) != 0,
        received: true
    }
  end

  def finish_tick(%__MODULE__{received: true} = motion), do: %{motion | received: false}

  def finish_tick(%__MODULE__{} = motion),
    do: %{motion | known_movement: {0.0, 0.0, 0.0}}

  def flight(%__MODULE__{} = motion, true), do: %{motion | fall_distance: 0.0, swimming: false}
  def flight(%__MODULE__{} = motion, false), do: motion

  def corrected(%__MODULE__{} = motion),
    do: %{motion | known_movement: {0.0, 0.0, 0.0}, received: false}
end
