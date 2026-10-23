defmodule Valimc.AI.Goal do
  @moduledoc """
  A goal (vanilla's `Goal`) as a module over its own state and the mob
  (`Valimc.AI.Self`). `can_use/2` and `can_continue/2` answer with the state
  and mob they changed (a draw of the mob's random is a change); `start/2`,
  `stop/2` and `tick/2` return both. `use Valimc.AI.Goal` gives vanilla's
  defaults: continue while usable, interruptable, nothing on start, stop or
  tick, updated every other tick.

  `adjusted/2` is `adjustedTickDelay`: a goal updated every other tick
  halves its delays.
  """
  alias Valimc.AI.Self

  @callback can_use(map, Self.t()) :: {boolean, map, Self.t()}
  @callback can_continue(map, Self.t()) :: {boolean, map, Self.t()}
  @callback start(map, Self.t()) :: {map, Self.t()}
  @callback stop(map, Self.t()) :: {map, Self.t()}
  @callback tick(map, Self.t()) :: {map, Self.t()}
  @callback every_tick?(map) :: boolean
  @callback interruptable?(map) :: boolean

  defmacro __using__(_) do
    quote do
      @behaviour Valimc.AI.Goal
      alias Valimc.AI.{Mth, Navigation, Self, World}

      def can_continue(state, self), do: can_use(state, self)
      def start(state, self), do: {state, self}
      def stop(state, self), do: {state, self}
      def tick(state, self), do: {state, self}
      def every_tick?(_state), do: false
      def interruptable?(_state), do: true

      defoverridable can_continue: 2,
                     start: 2,
                     stop: 2,
                     tick: 2,
                     every_tick?: 1,
                     interruptable?: 1

      @compile {:nowarn_unused_function, adjusted: 2}
      defp adjusted(state, ticks), do: Valimc.AI.Goal.adjusted(__MODULE__, state, ticks)
    end
  end

  @doc "`adjustedTickDelay` of goal `module` with `state`."
  def adjusted(module, state, ticks),
    do: if(module.every_tick?(state), do: ticks, else: Valimc.AI.Mth.reduced(ticks))
end
