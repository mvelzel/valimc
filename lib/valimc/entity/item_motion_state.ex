defmodule Valimc.Entity.ItemMotionState do
  @moduledoc "Bounded saved item kinematics; only a simulation owner advances these values."
  defstruct velocity: {0.0, 0.0, 0.0},
            age: 0,
            pickup_delay: 0,
            on_ground: false,
            no_gravity: false,
            # Ticks before a portal takes the item again (VMC-026c, vanilla's `portalCooldown`).
            portal_cooldown: 0,
            # An item's or orb's health and burning counter (VMC-034n4d,
            # `Health` and `remainingFireTicks`).
            health: 5,
            fire_ticks: 0

  def tick(%__MODULE__{} = state), do: advance(state, 1)

  @doc "Age by `ticks` game ticks at once (the infinite markers never change)."
  def advance(%__MODULE__{} = state, ticks) when is_integer(ticks) and ticks >= 1,
    do: %{
      state
      | age: if(state.age == -32_768, do: state.age, else: min(6000, state.age + ticks)),
        pickup_delay:
          if(state.pickup_delay == 32_767,
            do: state.pickup_delay,
            else: max(0, state.pickup_delay - ticks)
          ),
        portal_cooldown: max(0, state.portal_cooldown - ticks)
    }

  def valid?(%__MODULE__{
        velocity: {x, y, z},
        age: age,
        pickup_delay: delay,
        on_ground: on_ground,
        no_gravity: no_gravity,
        portal_cooldown: cooldown,
        health: health,
        fire_ticks: fire
      }),
      do:
        Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64)) and
          is_integer(age) and age in -32_768..6000 and
          is_integer(delay) and delay in 0..32_767 and
          is_boolean(on_ground) and is_boolean(no_gravity) and
          is_integer(cooldown) and cooldown in 0..32_767 and
          is_integer(health) and health in -32_768..32_767 and
          is_integer(fire) and fire in -32_768..32_767

  def valid?(_), do: false
end
