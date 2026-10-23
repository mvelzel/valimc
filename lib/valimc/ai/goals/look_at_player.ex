defmodule Valimc.AI.Goals.LookAtPlayer do
  @moduledoc """
  `LookAtPlayerGoal` for players: by chance (2% an update), the nearest
  player within its look distance (no line of sight needed beyond vanilla's
  non-combat test), looked at for 40 to 79 ticks while in range.
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  def new(distance, probability \\ 0.02),
    do: %{
      distance: Float32.round(distance),
      probability: Float32.round(probability),
      look_at: nil,
      time: 0
    }

  def can_use(state, self) do
    {f, self} = Self.float(self)

    if f >= state.probability do
      {false, state, self}
    else
      conditions = World.conditions(false, range: state.distance)
      {player, self} = World.nearest_player(self, conditions, self.x, Self.eye_y(self), self.z)
      {player != nil, %{state | look_at: World.ref(player)}, self}
    end
  end

  def can_continue(state, self) do
    target = World.entity(self.world, state.look_at)

    cond do
      target == nil or not target.alive ->
        {false, state, self}

      World.distance_sq(self, target) > Float32.round(state.distance * state.distance) ->
        {false, state, self}

      true ->
        {state.time > 0, state, self}
    end
  end

  def start(state, self) do
    {n, self} = Self.int(self, 40)
    {%{state | time: adjusted(state, 40 + n)}, self}
  end

  def stop(state, self), do: {%{state | look_at: nil}, self}

  def tick(state, self) do
    case World.entity(self.world, state.look_at) do
      %{alive: true} = target ->
        {%{state | time: state.time - 1},
         Self.look_at(self, {target.x, World.eye_y(target), target.z})}

      _ ->
        {state, self}
    end
  end
end
