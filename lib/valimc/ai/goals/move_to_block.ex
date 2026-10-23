defmodule Valimc.AI.Goals.MoveToBlock do
  @moduledoc """
  `MoveToBlockGoal`: every 100 to 199 updates it looks for a valid block
  within its search range (vanilla's spiral: nearest layers first), walks
  to stand on it and stays there; it gives up after 1,200 ticks away or a
  random stay. `valid` is the goal's own test, `fn self, cell, state ->
  {valid, state} end`; `reached` and `tick` let a goal act there (a
  rabbit's `RaidGardenGoal`). Updated every tick.
  """
  use Valimc.AI.Goal

  def new(speed, range, valid, opts \\ []),
    do: %{
      speed: speed * 1.0,
      range: range,
      vertical: Keyword.get(opts, :vertical, 1),
      vertical_start: Keyword.get(opts, :vertical_start, 0),
      recalculate: Keyword.get(opts, :recalculate, 40),
      valid: valid,
      next: 0,
      tries: 0,
      stay: 0,
      cell: {0, 0, 0},
      reached: false,
      own: Keyword.get(opts, :own, %{})
    }

  def every_tick?(_state), do: true

  def can_use(%{next: next} = state, self) when next > 0,
    do: {false, %{state | next: next - 1}, self}

  def can_use(state, self) do
    {n, self} = Self.int(self, 200)
    state = %{state | next: Mth.reduced(200 + n)}
    find(state, self)
  end

  @doc "`findNearestBlock`: `{found, state, self}`."
  def find(state, self) do
    {bx, by, bz} = Self.block(self)
    r = state.range

    cells =
      for y <- ys(state.vertical_start, state.vertical),
          ring <- 0..(r - 1),
          x <- spiral(0, ring),
          z <- spiral(if(x < ring and x > -ring, do: ring, else: 0), ring),
          do: {bx + x, by + y - 1, bz + z}

    # Only within the mob's home (VMC-043c3).
    Enum.reduce_while(cells, {false, state}, fn cell, {_, state} ->
      with true <- Valimc.AI.RandomPos.within_home?(self, cell),
           {true, state} <- state.valid.(self, cell, state) do
        {:halt, {true, %{state | cell: cell}}}
      else
        false -> {:cont, {false, state}}
        {false, state} -> {:cont, {false, state}}
      end
    end)
    |> then(fn {found, state} -> {found, state, self} end)
  end

  # `for (y = start; y <= v; y = y > 0 ? -y : 1 - y)`: 0, 1, -1, 2, -2, ...
  defp ys(start, v),
    do: Stream.iterate(start, &if(&1 > 0, do: -&1, else: 1 - &1)) |> Enum.take_while(&(&1 <= v))

  # `for (x = from; x <= r; x = x > 0 ? -x : 1 - x)`.
  defp spiral(from, r),
    do: Stream.iterate(from, &if(&1 > 0, do: -&1, else: 1 - &1)) |> Enum.take_while(&(&1 <= r))

  def can_continue(state, self) do
    if state.tries >= -state.stay and state.tries <= 1200 do
      {valid, state} = state.valid.(self, state.cell, state)
      {valid, state, self}
    else
      {false, state, self}
    end
  end

  def start(state, self) do
    {x, y, z} = state.cell
    {_, self} = Navigation.move_to(self, {x + 0.5, y + 1.0, z + 0.5}, state.speed)
    {a, self} = Self.int(self, 1200)
    {b, self} = Self.int(self, a + 1200)
    {%{state | tries: 0, stay: b + 1200}, self}
  end

  def tick(state, self) do
    {x, y, z} = state.cell
    target = {x, y + 1, z}

    if close?(target, self, 1.0) do
      {%{state | reached: true, tries: state.tries - 1}, self}
    else
      tries = state.tries + 1

      self =
        if rem(tries, state.recalculate) == 0 do
          {_, self} = Navigation.move_to(self, {x + 0.5, y + 1.0, z + 0.5}, state.speed)
          self
        else
          self
        end

      {%{state | reached: false, tries: tries}, self}
    end
  end

  # `BlockPos.closerToCenterThan(position, distance)`.
  defp close?({x, y, z}, self, d) do
    {dx, dy, dz} = {x + 0.5 - self.x, y + 0.5 - self.y, z + 0.5 - self.z}
    dx * dx + dy * dy + dz * dz < d * d
  end
end
