defmodule Valimc.AI.Goals.OcelotAttack do
  @moduledoc """
  `OcelotAttackGoal` (a cat's, VMC-044a3): it goes for its target while it
  lives within fifteen blocks, looking at it, sprinting when it is close,
  creeping within fifteen blocks and walking otherwise, and within twice
  its width hits it every 20 ticks (`doHurtTarget`, without a swing).
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  def new, do: %{target: nil, attack_time: 0}

  def can_use(state, self) do
    case World.target(self) do
      nil -> {false, state, self}
      target -> {true, %{state | target: World.ref(target)}, self}
    end
  end

  def can_continue(state, self) do
    target = World.entity(self.world, state.target)

    cond do
      target == nil or not Map.get(target, :alive, true) -> {false, state, self}
      World.distance_sq(self, target) > 225.0 -> {false, state, self}
      not Navigation.done?(self.mind.navigation) -> {true, state, self}
      true -> can_use(state, self)
    end
  end

  def stop(state, self), do: {%{state | target: nil}, Navigation.stop(self)}

  def every_tick?(_state), do: true

  def tick(state, self) do
    case World.entity(self.world, state.target) do
      nil ->
        {state, self}

      target ->
        self = Self.look_at(self, {target.x, World.eye_y(target), target.z}, 30.0, 30.0)
        twice = Float32.round(self.width * 2.0)
        melee = Float32.round(twice * twice)
        distance = World.distance_sq(self, target)

        speed =
          cond do
            distance > melee and distance < 16.0 -> 1.33
            distance < 225.0 -> 0.6
            true -> 0.8
          end

        {_, self} = Navigation.move_to_entity(self, target, speed)
        state = %{state | attack_time: max(state.attack_time - 1, 0)}

        if distance <= melee and state.attack_time <= 0 do
          self = Self.effect(self, {:attack, World.ref(target)})
          {%{state | attack_time: 20}, Valimc.AI.Mobs.hit(self, target)}
        else
          {state, self}
        end
    end
  end
end
