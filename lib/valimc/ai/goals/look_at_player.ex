defmodule Valimc.AI.Goals.LookAtPlayer do
  @moduledoc """
  `LookAtPlayerGoal` for players: by chance (2% an update), the nearest
  player within its look distance (no line of sight needed beyond vanilla's
  non-combat test), looked at for 40 to 79 ticks while in range; with
  `only_horizontal` (a shulker) at its own eye height. With `types` it
  looks at the nearest section mob of those types instead, within its
  distance and three blocks up or down of its box (a guardian at another).
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  def new(distance, probability \\ 0.02, opts \\ []),
    do: %{
      distance: Float32.round(distance),
      probability: Float32.round(probability),
      only_horizontal: Keyword.get(opts, :only_horizontal, false),
      types: Keyword.get(opts, :types),
      look_at: nil,
      time: 0
    }

  def can_use(state, self) do
    {f, self} = Self.float(self)

    if f >= state.probability do
      {false, state, self}
    else
      conditions = World.conditions(false, range: state.distance)
      {found, self} = nearest(state, self, conditions)
      {found != nil, %{state | look_at: World.ref(found)}, self}
    end
  end

  defp nearest(%{types: nil}, self, conditions),
    do: World.nearest_player(self, conditions, self.x, Self.eye_y(self), self.z)

  defp nearest(%{types: types, distance: d}, self, conditions) do
    box = World.inflate(Self.box(self), d, 3.0, d)
    World.nearest_mob(self, types, box, conditions, self.x, Self.eye_y(self), self.z)
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
        y = if state.only_horizontal, do: Self.eye_y(self), else: World.eye_y(target)
        {%{state | time: state.time - 1}, Self.look_at(self, {target.x, y, target.z})}

      _ ->
        {state, self}
    end
  end
end
