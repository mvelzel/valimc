defmodule Valimc.AI.Goals.RangedBowAttack do
  @moduledoc """
  `RangedBowAttackGoal` (VMC-043b: skeletons): while it has a target and
  holds a bow, it walks toward the target until within its radius and in
  sight for a second, then holds still and circles it (strafing, switching
  direction now and then by chance, backing off close by), looking at it;
  it draws the bow when its cooldown is over and shoots once the bow has
  been drawn for a second and the target is in sight (a `{:shoot, ...}`
  effect, `performRangedAttack`, with the shot's sound pitch from its
  random), or lets go after three seconds out of sight.
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  @bow Valimc.Protocol.ItemTypes.id("bow")

  def new(speed, interval, radius),
    do: %{
      speed: speed * 1.0,
      interval: interval,
      radius_sq: Float32.round(Float32.round(radius) * Float32.round(radius)),
      attack_time: -1,
      see_time: 0,
      clockwise: false,
      backwards: false,
      strafing_time: -1
    }

  @doc "`setMinAttackInterval`."
  def interval(state, ticks), do: %{state | interval: ticks}

  def can_use(state, self), do: {World.target(self) != nil and holding?(self), state, self}

  def can_continue(state, self) do
    {(World.target(self) != nil or not Navigation.done?(self.mind.navigation)) and holding?(self),
     state, self}
  end

  defp holding?(self), do: Self.holding?(self, @bow)

  def start(state, self), do: {state, Self.set_aggressive(self, true)}

  def stop(state, self) do
    self = self |> Self.set_aggressive(false) |> Self.stop_using()
    {%{state | see_time: 0, attack_time: -1}, self}
  end

  def every_tick?(_state), do: true

  def tick(state, self) do
    case World.target(self) do
      nil -> {state, self}
      target -> fight(state, self, target)
    end
  end

  defp fight(state, self, target) do
    distance = World.distance_sq(self, target)
    {seen, self} = World.sees?(self, target)
    state = if seen != state.see_time > 0, do: %{state | see_time: 0}, else: state
    state = %{state | see_time: state.see_time + if(seen, do: 1, else: -1)}

    {state, self} =
      if not (distance > state.radius_sq) and state.see_time >= 20 do
        {%{state | strafing_time: state.strafing_time + 1}, Navigation.stop(self)}
      else
        {_, self} = Navigation.move_to_entity(self, target, state.speed, 0)
        {%{state | strafing_time: -1}, self}
      end

    {state, self} =
      if state.strafing_time >= 20 do
        {f, self} = Self.float(self)
        state = if f < 0.3, do: %{state | clockwise: not state.clockwise}, else: state
        {f, self} = Self.float(self)
        state = if f < 0.3, do: %{state | backwards: not state.backwards}, else: state
        {%{state | strafing_time: 0}, self}
      else
        {state, self}
      end

    {state, self} =
      if state.strafing_time > -1 do
        state =
          cond do
            distance > Float32.round(state.radius_sq * Float32.round(0.75)) ->
              %{state | backwards: false}

            distance < Float32.round(state.radius_sq * Float32.round(0.25)) ->
              %{state | backwards: true}

            true ->
              state
          end

        self =
          self
          |> Self.strafe(
            if(state.backwards, do: -0.5, else: 0.5),
            if(state.clockwise, do: 0.5, else: -0.5)
          )
          |> Self.look_at_entity(target, 30.0, 30.0)

        {state, self}
      else
        {state, Self.look_at(self, {target.x, World.eye_y(target), target.z}, 30.0, 30.0)}
      end

    shoot(state, self, target, distance, seen)
  end

  defp shoot(state, self, target, _distance, seen) do
    cond do
      Self.using?(self) ->
        cond do
          not seen and state.see_time < -60 ->
            {state, Self.stop_using(self)}

          seen and Self.ticks_using(self) >= 20 ->
            power = power(Self.ticks_using(self))
            self = self |> Self.stop_using() |> perform(target, power)
            {%{state | attack_time: state.interval}, self}

          true ->
            {state, self}
        end

      state.attack_time - 1 <= 0 and state.see_time >= -60 ->
        {%{state | attack_time: state.attack_time - 1}, Self.start_using(self, hand(self))}

      true ->
        {%{state | attack_time: state.attack_time - 1}, self}
    end
  end

  # `ProjectileUtil.getWeaponHoldingHand`: the main hand unless only the off
  # hand holds a bow.
  defp hand(self) do
    if match?(%{item_id: @bow}, self.mob.equipment[:mainhand]), do: :main_hand, else: :off_hand
  end

  @doc "`BowItem.getPowerForTime`."
  def power(ticks) do
    f = Float32.round(ticks / 20.0)
    f = Float32.round(Float32.round(Float32.round(f * f) + Float32.round(f * 2.0)) / 3.0)
    min(f, 1.0)
  end

  # `performRangedAttack`: an arrow at the target (made by the owner), then
  # the shot's sound with the mob's own pitch draw.
  defp perform(self, target, power) do
    {f, self} = Self.float(self)

    pitch =
      Float32.round(
        1.0 / Float32.round(Float32.round(f * Float32.round(0.4)) + Float32.round(0.8))
      )

    Self.effect(
      self,
      {:shoot,
       %{
         target: World.ref(target),
         at: {target.x, target.y, target.z, target.height},
         from: {self.x, Self.eye_y(self), self.z},
         power: power,
         pitch: pitch
       }}
    )
  end
end
