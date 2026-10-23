defmodule Valimc.AI.Goals.RandomStroll do
  @moduledoc """
  `RandomStrollGoal` and `WaterAvoidingRandomStrollGoal` (`water_avoiding`):
  now and then (one chance in half its interval per update), unless idle for
  100 ticks, a walk to a random target ten blocks around; a water-avoiding
  stroll picks land targets (from water, fifteen blocks around), all but a
  thousandth of the time.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos

  def new(speed, opts \\ []),
    do: %{
      speed: speed * 1.0,
      interval: Keyword.get(opts, :interval, 120),
      check_idle: Keyword.get(opts, :check_idle, true),
      water_avoiding: Keyword.get(opts, :water_avoiding, false),
      probability: Valimc.Data.Float32.round(Keyword.get(opts, :probability, 0.001)),
      force: false,
      wanted: nil
    }

  def can_use(state, self) do
    cond do
      not state.force and state.check_idle and self.mind.no_action >= 100 ->
        {false, state, self}

      true ->
        {go, self} =
          if state.force do
            {true, self}
          else
            {n, self} = Self.int(self, Mth.reduced(state.interval))
            {n == 0, self}
          end

        if go do
          case position(state, self) do
            {nil, self} -> {false, state, self}
            {pos, self} -> {true, %{state | wanted: pos, force: false}, self}
          end
        else
          {false, state, self}
        end
    end
  end

  defp position(%{water_avoiding: false}, self), do: RandomPos.default(self, 10, 7)

  defp position(state, self) do
    if Self.in_water?(self) do
      case RandomPos.land(self, 15, 7) do
        {nil, self} -> RandomPos.default(self, 10, 7)
        found -> found
      end
    else
      {f, self} = Self.float(self)

      if f >= state.probability,
        do: RandomPos.land(self, 10, 7),
        else: RandomPos.default(self, 10, 7)
    end
  end

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.wanted, state.speed)
    {state, self}
  end

  def stop(state, self), do: {state, Navigation.stop(self)}
end
