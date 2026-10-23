defmodule Valimc.AI.Goals.FollowParent do
  @moduledoc """
  `FollowParentGoal`: a baby follows the nearest adult of its type within
  eight blocks (four up and down) once more than three away, repathing every
  ten ticks, until within three or past sixteen blocks.
  """
  use Valimc.AI.Goal

  def new(speed), do: %{speed: speed * 1.0, parent: nil, recalculate: 0}

  def can_use(state, self) do
    if self.mind.age >= 0 do
      {false, state, self}
    else
      box = World.inflate(Self.box(self), 8.0, 4.0, 8.0)

      {closest, distance} =
        self
        |> World.mobs_in([self.type], box)
        |> Enum.reduce({nil, :infinity}, fn other, {best, d} ->
          od = World.distance_sq(self, other)
          if other.age >= 0 and (d == :infinity or not (od > d)), do: {other, od}, else: {best, d}
        end)

      cond do
        closest == nil -> {false, state, self}
        distance < 9.0 -> {false, state, self}
        true -> {true, %{state | parent: World.ref(closest)}, self}
      end
    end
  end

  def can_continue(state, self) do
    case World.entity(self.world, state.parent) do
      %{alive: true} = parent when self.mind.age < 0 ->
        d = World.distance_sq(self, parent)
        {not (d < 9.0) and not (d > 256.0), state, self}

      _ ->
        {false, state, self}
    end
  end

  def start(state, self), do: {%{state | recalculate: 0}, self}
  def stop(state, self), do: {%{state | parent: nil}, self}

  def tick(state, self) do
    recalculate = state.recalculate - 1

    if recalculate <= 0 do
      case World.entity(self.world, state.parent) do
        nil ->
          {%{state | recalculate: adjusted(state, 10)}, self}

        parent ->
          {_, self} = Navigation.move_to_entity(self, parent, state.speed)
          {%{state | recalculate: adjusted(state, 10)}, self}
      end
    else
      {%{state | recalculate: recalculate}, self}
    end
  end
end
