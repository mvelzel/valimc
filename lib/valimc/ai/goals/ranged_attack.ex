defmodule Valimc.AI.Goals.RangedAttack do
  @moduledoc """
  `RangedAttackGoal` (VMC-043b6: a witch's potions; a drowned's trident):
  while it has a living target it walks toward it until within its radius
  and in sight for five ticks, looking at it; when its countdown reaches
  zero in sight it attacks (`perform`, a function of the mob, the target
  and the power, the distance over the radius kept within 0.1 to 1) and
  waits between its least and most interval by that distance.
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  def new(speed, min, max, radius, perform) do
    radius = Float32.round(radius)

    %{
      speed: speed * 1.0,
      min: min,
      max: max,
      radius: radius,
      radius_sq: Float32.round(radius * radius),
      perform: perform,
      target: nil,
      attack_time: -1,
      see_time: 0
    }
  end

  def can_use(state, self) do
    case World.target(self) do
      %{alive: true} = target -> {true, %{state | target: World.ref(target)}, self}
      _ -> {false, state, self}
    end
  end

  def can_continue(state, self) do
    case can_use(state, self) do
      {true, state, self} ->
        {true, state, self}

      {false, state, self} ->
        alive = match?(%{alive: true}, World.entity(self.world, state.target))
        {alive and not Navigation.done?(self.mind.navigation), state, self}
    end
  end

  def stop(state, self), do: {%{state | target: nil, see_time: 0, attack_time: -1}, self}

  def every_tick?(_state), do: true

  def tick(state, self) do
    case World.entity(self.world, state.target) do
      nil -> {state, self}
      target -> fight(state, self, target)
    end
  end

  defp fight(state, self, target) do
    distance = Self.distance_sq(self, {target.x, target.y, target.z})
    {seen, self} = World.sees?(self, target)
    state = %{state | see_time: if(seen, do: state.see_time + 1, else: 0)}

    self =
      if not (distance > state.radius_sq) and state.see_time >= 5 do
        Navigation.stop(self)
      else
        {_, self} = Navigation.move_to_entity(self, target, state.speed, 0)
        self
      end

    self = Self.look_at(self, {target.x, World.eye_y(target), target.z}, 30.0, 30.0)
    attack_time = state.attack_time - 1

    cond do
      attack_time == 0 and not seen ->
        {%{state | attack_time: attack_time}, self}

      attack_time == 0 ->
        dist = Float32.round(Float32.round(:math.sqrt(distance)) / state.radius)
        power = dist |> max(Float32.round(0.1)) |> min(1.0)
        self = state.perform.(self, target, power)
        next = floor(Float32.round(dist * (state.max - state.min) + state.min))
        {%{state | attack_time: next}, self}

      attack_time < 0 ->
        delta = :math.sqrt(distance) / state.radius
        {%{state | attack_time: floor(state.min + delta * (state.max - state.min))}, self}

      true ->
        {%{state | attack_time: attack_time}, self}
    end
  end
end
