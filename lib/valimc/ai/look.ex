defmodule Valimc.AI.Look do
  @moduledoc """
  Vanilla's `LookControl` and `BodyRotationControl` (VMC-041a). The look
  control runs after the goals and navigation, before the move: toward the
  wanted look for two ticks after a goal sets it (the head's yaw by at most
  the goal's speed, the pitch by its limit), else the head back toward the
  body; the head stays within its limit of the body while the mob
  navigates. The body control runs after the move: a moving body faces its
  yaw and pulls the head within the limit; a still one follows a head that
  turned past 15 degrees, and after ten still ticks turns toward the head
  over ten more.
  """
  alias Valimc.AI.{Mth, Navigation, Self}
  alias Valimc.Data.Float32

  # Float constants as Java widens them.
  @still Float32.round(2.5000003e-7)
  @near Float32.round(1.0e-5)

  @doc "`LookControl.tick`."
  def tick(%Self{mind: mind} = self) do
    # `resetXRotOnTick`.
    self = %{self | pitch: 0.0}

    self =
      case mind.look do
        %{cooldown: cooldown} = look when cooldown > 0 ->
          self = %{self | mind: %{mind | look: %{look | cooldown: cooldown - 1}}}
          {dx, dy, dz} = {look.x - self.x, look.y - Self.eye_y(self), look.z - self.z}

          self =
            if abs(dz) > @near or abs(dx) > @near,
              do: %{self | head: Mth.rotate_towards(self.head, Mth.yaw(dx, dz), look.y_max)},
              else: self

          sd = :math.sqrt(dx * dx + dz * dz)

          if abs(dy) > @near or abs(sd) > @near,
            do: %{self | pitch: Mth.rotate_towards(self.pitch, Mth.pitch(dy, sd), look.x_max)},
            else: self

        _ ->
          %{self | head: Mth.rotate_towards(self.head, mind.body_yaw, 10.0)}
      end

    if Navigation.done?(self.mind.navigation),
      do: self,
      else: %{
        self
        | head: Mth.rotate_if_necessary(self.head, self.mind.body_yaw, self.facts.max_head_y_rot)
      }
  end

  @doc """
  `BodyRotationControl.clientTick` after the move from `{xo, zo}`: the body's
  yaw, and the head pulled within reach of it.
  """
  def body(%Self{mind: mind} = self, {xo, zo}) do
    {dx, dz} = {self.x - xo, self.z - zo}
    limit = self.facts.max_head_y_rot

    if dx * dx + dz * dz > @still do
      head = Mth.rotate_if_necessary(self.head, self.yaw, limit)
      %{self | head: head, mind: %{mind | body_yaw: self.yaw, stable_head: head, stable_time: 0}}
    else
      if abs(Float32.round(self.head - mind.stable_head)) > 15.0 do
        body = Mth.rotate_if_necessary(mind.body_yaw, self.head, limit)
        %{self | mind: %{mind | stable_time: 0, stable_head: self.head, body_yaw: body}}
      else
        time = mind.stable_time + 1

        body =
          if time > 10 do
            fraction = Mth.clamp(Float32.round((time - 10) / 10.0), 0.0, 1.0)
            remaining = Float32.round(limit * Float32.round(1.0 - fraction))
            Mth.rotate_if_necessary(mind.body_yaw, self.head, remaining)
          else
            mind.body_yaw
          end

        %{self | mind: %{mind | stable_time: time, body_yaw: body}}
      end
    end
  end
end
