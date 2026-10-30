defmodule Valimc.Entity.MobMotion do
  @moduledoc """
  A mob's travel state between ticks (VMC-015i), as vanilla's `LivingEntity`
  and `MoveControl` keep it: fall distance, jump delay, the slowing block's
  multiplier, the relative input and speed, the move control's operation
  and the last horizontal collision, as a mob's record holds it. A native
  mob's tick runs it through the physics kernel (`valimc_core::mobs::tick`).

  `control` is `:wait`, `{:move_to, {x, y, z}, speed}`, `{:strafe,
  forward, right, speed}` (VMC-043b) or `{:jumping,
  speed}`: what the AI (VMC-041a) sets each tick, as navigation sets
  `MoveControl.setWantedPosition`; `jump` is its `JumpControl.jump()` for the
  tick. `water` and `lava` are the fluid heights the last move left, and
  `powder_snow` whether it ended inside powder snow and `vertical_collision`
  whether it was stopped vertically, which the AI reads. A rabbit's `hop`
  (VMC-043c) keeps its hopping controls: whether it is jumping, its wanted
  position and speeds (`RabbitMoveControl`).

  A family that runs its own move control in the AI (a fish's, VMC-043e)
  sets `set` for the tick (`{speed, lift}`: `setSpeed`, and a lift while its
  eyes are in water; or `{speed, lift, {xxa, yya, zza}}`, the inputs a smooth
  swimmer's control sets, nil keeping `setSpeed`'s), `impulse` (motion added
  after the dead zone) and `travel` (`{:fish | :guardian | :dolphin, sink}`;
  its type's travel otherwise); its `control` then keeps the operation and
  wanted position its move control reads. `up` is its vertical input
  (`yya`), and `pre_move` a goal's own move before the travel
  (`BreathAirGoal`).
  A ghast's `float` (VMC-043d) keeps its move control's wanted place (nil:
  it waits) and float timer (`GhastMoveControl`, in the kernel, which draws
  on its mind's random).
  """
  defstruct fall_distance: 0.0,
            no_jump_delay: 0,
            stuck_multiplier: {0.0, 0.0, 0.0},
            strafe: 0.0,
            up: 0.0,
            forward: 0.0,
            speed: 0.0,
            control: :wait,
            horizontal_collision: false,
            jump: false,
            rise: false,
            water: 0.0,
            lava: 0.0,
            powder_snow: false,
            # Its eye's water and block where the last move left it (what the
            # next base tick reads: `isEyeInFluid`).
            eye: {false, 0},
            hop: nil,
            vertical_collision: false,
            set: nil,
            pre_move: nil,
            impulse: {0.0, 0.0, 0.0},
            travel: nil,
            move_dist: 0.0,
            next_step: 1.0,
            float: nil,
            # Its eyes in water after its last move (`isEyeInFluid(WATER)`).
            eye_water: false,
            support: nil

  def valid?(%__MODULE__{} = m),
    do:
      is_float(m.fall_distance) and is_integer(m.no_jump_delay) and m.no_jump_delay in 0..10 and
        vector?(m.stuck_multiplier) and
        Enum.all?([m.strafe, m.up, m.forward, m.speed], &is_float/1) and
        is_boolean(m.horizontal_collision) and control?(m.control) and is_boolean(m.jump) and
        is_boolean(Map.get(m, :rise)) and
        is_float(m.water) and is_float(m.lava) and is_boolean(m.powder_snow) and hop?(m.hop) and
        is_boolean(m.vertical_collision) and is_float(m.move_dist) and is_float(m.next_step) and
        float?(Map.get(m, :float, :missing))

  def valid?(_), do: false

  defp hop?(nil), do: true

  defp hop?(%{jumping: jumping, wanted: wanted, speed: speed, next_speed: next}),
    do:
      is_boolean(jumping) and (wanted == nil or vector?(wanted)) and is_float(speed) and
        is_float(next)

  defp hop?(_), do: false

  defp float?(nil), do: true

  defp float?(%{wanted: wanted, duration: duration}),
    do: (wanted == nil or vector?(wanted)) and is_integer(duration)

  defp float?(_), do: false

  defp control?(:wait), do: true
  defp control?({:move_to, target, speed}), do: vector?(target) and is_float(speed)
  defp control?({:jumping, speed}), do: is_float(speed)

  defp control?({:strafe, forward, right, speed}),
    do: is_float(forward) and is_float(right) and is_float(speed)

  defp control?(_), do: false

  defp vector?({x, y, z}), do: is_float(x) and is_float(y) and is_float(z)
  defp vector?(_), do: false
end
