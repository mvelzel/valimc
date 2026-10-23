defmodule Valimc.AI.SmoothSwimming do
  @moduledoc """
  Vanilla's `SmoothSwimmingMoveControl` and `SmoothSwimmingLookControl`
  (VMC-043e: dolphins, axolotls), as a family's `move_control/1` and
  `look_control/1` run them.

  The move control, with `max_x` and `max_y` (its pitch's and yaw's turns),
  `in_water` and `out` (its speed's fractions in and out of water) and
  `gravity` (a little lift in water): toward the wanted position while the
  mob navigates (its yaw, body and head turned at most `max_y`; in water
  its pitch five degrees toward the target, within `max_x`, its input
  forward and up by its pitch; out of water slower while it still has to
  turn), else still. The look control: toward the wanted look 20 degrees
  past it and 10 below, else level (while still) and the head back to the
  body; the body follows a head more than `max_from_center` off, four
  degrees a tick.
  """
  alias Valimc.AI.{Look, Mth, Navigation, Self}
  alias Valimc.Data.Float32
  alias Valimc.Data.Mth, as: Table

  @radians Float32.round(:math.pi() / 180.0)

  @doc "`SmoothSwimmingMoveControl.tick` with its `controls`."
  def move(%Self{mob: mob} = self, controls) do
    in_water = Self.in_water?(self)
    lift = if controls.gravity and in_water, do: [{0.0, 0.005, 0.0}], else: []

    self =
      case mob.motion.control do
        {:move_to, wanted, modifier} ->
          if Navigation.done?(self.mind.navigation),
            do: set(self, 0.0, {0.0, 0.0, 0.0}),
            else: steer(self, wanted, modifier, in_water, controls)

        _ ->
          set(self, 0.0, {0.0, 0.0, 0.0})
      end

    %{self | mob: %{self.mob | motion: %{self.mob.motion | impulse: lift}}}
  end

  defp steer(self, {wx, wy, wz}, modifier, in_water, controls) do
    {xd, yd, zd} = {wx - self.x, wy - self.y, wz - self.z}

    if xd * xd + yd * yd + zd * zd < Float32.round(2.5000003e-7) do
      # Only its forward input stops.
      set(self, Self.speed(self), {nil, nil, 0.0})
    else
      wanted = Mth.yaw(xd, zd)
      yaw = Mth.rotlerp(self.yaw, wanted, controls.max_y)
      self = Self.mind(%{self | yaw: yaw, head: yaw}, &%{&1 | body_yaw: yaw})
      attribute = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:movement_speed")
      speed = Float32.round(modifier * attribute)

      if in_water do
        sqrt = :math.sqrt(xd * xd + zd * zd)
        near = Float32.round(1.0e-5)

        self =
          if abs(yd) > near or abs(sqrt) > near do
            pitch = Mth.clamp(Mth.wrap(Mth.pitch(yd, sqrt)), -controls.max_x, controls.max_x)
            %{self | pitch: Mth.rotate_towards(self.pitch, pitch, 5.0)}
          else
            self
          end

        angle = Float32.round(self.pitch * @radians)
        {cos, sin} = {Table.cos(angle), Table.sin(angle)}

        set(
          self,
          Float32.round(speed * Float32.round(controls.in_water)),
          {nil, Float32.round(-sin * speed), Float32.round(cos * speed)}
        )
      else
        left = abs(Mth.wrap(Float32.round(self.yaw - wanted)))
        factor = Float32.round(1.0 - Mth.clamp(Float32.round((left - 10.0) / 50.0), 0.0, 1.0))

        set(
          self,
          Float32.round(Float32.round(speed * Float32.round(controls.out)) * factor),
          {nil, nil, nil}
        )
      end
    end
  end

  # `setSpeed` and the inputs it sets itself (nil: `setSpeed`'s).
  defp set(%Self{mob: mob} = self, speed, inputs) do
    %{self | mob: %{mob | motion: %{mob.motion | set: {speed * 1.0, false, inputs}}}}
  end

  @doc "`SmoothSwimmingLookControl.tick` with `max_from_center`."
  def look(%Self{mind: mind} = self, max_from_center) do
    self =
      case mind.look do
        %{cooldown: cooldown} = look when cooldown > 0 ->
          self = Self.mind(self, &%{&1 | look: %{look | cooldown: cooldown - 1}})
          {yaw, pitch} = Look.wanted(self, look)

          self =
            if yaw,
              do: %{
                self
                | head: Mth.rotate_towards(self.head, Float32.round(yaw + 20.0), look.y_max)
              },
              else: self

          if pitch,
            do: %{
              self
              | pitch: Mth.rotate_towards(self.pitch, Float32.round(pitch + 10.0), look.x_max)
            },
            else: self

        look ->
          self =
            if Navigation.done?(mind.navigation),
              do: %{self | pitch: Mth.rotate_towards(self.pitch, 0.0, 5.0)},
              else: self

          speed = if look, do: look.y_max, else: 0.0
          %{self | head: Mth.rotate_towards(self.head, self.mind.body_yaw, speed)}
      end

    diff = Mth.wrap(Float32.round(self.head - self.mind.body_yaw))

    cond do
      diff < -max_from_center ->
        Self.mind(self, &%{&1 | body_yaw: Float32.round(&1.body_yaw - 4.0)})

      diff > max_from_center ->
        Self.mind(self, &%{&1 | body_yaw: Float32.round(&1.body_yaw + 4.0)})

      true ->
        self
    end
  end
end
