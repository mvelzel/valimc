defmodule Valimc.AI.Goals.AvoidEntity do
  @moduledoc """
  `AvoidEntityGoal`: the nearest entity it avoids within its distance
  (`select` takes a sensed entity; creative and spectator players are never
  avoided), fled to a random target up to sixteen blocks away that is
  farther from it, walking, and sprinting within seven blocks.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos
  alias Valimc.Data.Float32

  def new(select, distance, walk, sprint),
    do: %{
      select: select,
      distance: Float32.round(distance),
      walk: walk * 1.0,
      sprint: sprint * 1.0,
      avoid: nil,
      path: nil
    }

  def can_use(state, self) do
    select = fn target ->
      state.select.(target) and
        not (target.kind == :player and target.mode in [:creative, :spectator])
    end

    conditions = World.conditions(true, range: state.distance, select: select)
    box = World.inflate(Self.box(self), state.distance, 3.0, state.distance)
    candidates = candidates(self, state, box)
    {avoid, self} = nearest(self, candidates, conditions)

    if avoid == nil do
      {false, %{state | avoid: nil}, self}
    else
      state = %{state | avoid: World.ref(avoid)}

      case RandomPos.default_away(self, 16, 7, {avoid.x, avoid.y, avoid.z}) do
        {nil, self} ->
          {false, state, self}

        {{x, y, z} = pos, self} ->
          {dx, dy, dz} = {avoid.x - x, avoid.y - y, avoid.z - z}

          if dx * dx + dy * dy + dz * dz < World.distance_sq(self, avoid) do
            {false, state, self}
          else
            {path, self} = Navigation.path_to(self, pos, 0)
            {path != nil, %{state | path: path}, self}
          end
      end
    end
  end

  defp candidates(self, state, box) do
    players =
      for p <- self.world.players, state.select.(p), World.intersects?(World.box(p), box), do: p

    players ++ World.mobs_in(self, fn _ -> true end, box)
  end

  defp nearest(self, candidates, conditions) do
    {best, _, self} =
      Enum.reduce(candidates, {nil, -1.0, self}, fn c, {best, d, self} ->
        {passes, self} = World.test(self, c, conditions)
        distance = World.distance_sq(self, c)

        if passes and (d == -1.0 or distance < d),
          do: {c, distance, self},
          else: {best, d, self}
      end)

    {best, self}
  end

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.follow(self, state.path, state.walk)
    {state, self}
  end

  def stop(state, self), do: {%{state | avoid: nil}, self}

  def tick(state, self) do
    case World.entity(self.world, state.avoid) do
      nil ->
        {state, self}

      avoid ->
        speed = if World.distance_sq(self, avoid) < 49.0, do: state.sprint, else: state.walk
        {state, Navigation.speed(self, speed)}
    end
  end
end
