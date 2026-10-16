defmodule Valimc.ItemMotionState do
  @moduledoc "Bounded saved item kinematics; only a simulation owner advances these values."
  defstruct velocity: {0.0, 0.0, 0.0},
            age: 0,
            pickup_delay: 0,
            on_ground: false,
            no_gravity: false

  def valid?(%__MODULE__{
        velocity: {x, y, z},
        age: age,
        pickup_delay: delay,
        on_ground: on_ground,
        no_gravity: no_gravity
      }),
      do:
        Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64)) and
          is_integer(age) and age in -32_768..6000 and
          is_integer(delay) and delay in 0..32_767 and
          is_boolean(on_ground) and is_boolean(no_gravity)

  def valid?(_), do: false
end
