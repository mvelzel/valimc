defmodule Valimc.AI.Behavior do
  @moduledoc """
  A brain's behaviour (vanilla's `BehaviorControl`): a map whose `:kind`
  module tries to start it, ticks or stops it while it runs, and stops it.
  The kinds are vanilla's: `Timed` (`Behavior`: memory conditions, a run
  time drawn from the level's random, a tick while it can still be used),
  `OneShot` (a trigger that runs once and stops on its next tick), `Gate`
  (`RunOne`: children shuffled by their own random, the first that starts
  runs) and `DoNothing`.
  """
  alias Valimc.AI.{Brain, Self}

  @callback try_start(map, Self.t()) :: {boolean, map, Self.t()}
  @callback tick_or_stop(map, Self.t()) :: {map, Self.t()}
  @callback stop(map, Self.t()) :: {map, Self.t()}

  @doc "A draw from the level's random (`level.getRandom().nextInt(bound)`)."
  def level_int(%Self{world: world} = self, bound) do
    {n, random} = Valimc.AI.Random.int(world.random, bound)
    {n, %{self | world: %{world | random: random}}}
  end

  @doc "A draw from the level's random (`nextFloat()`)."
  def level_float(%Self{world: world} = self) do
    {f, random} = Valimc.AI.Random.float(world.random)
    {f, %{self | world: %{world | random: random}}}
  end

  @doc """
  A one-shot behaviour: `conditions` on memories, then `trigger.(self)`
  (`{started, self}`), or with its own `state` (what vanilla's closures
  keep) `trigger.(self, state)` (`{started, self, state}`).
  """
  def one_shot(conditions, trigger),
    do: %{kind: __MODULE__.OneShot, conditions: conditions, trigger: trigger}

  def one_shot(conditions, state, trigger),
    do: %{kind: __MODULE__.OneShot, conditions: conditions, trigger: trigger, state: state}

  @doc """
  A timed behaviour run by `module` with `state`, for `min` to `max` ticks
  (`:forever`: one whose `timedOut` is false, run while it may be, after
  vanilla's default 60-tick draw).
  """
  def timed(module, conditions, duration, state \\ %{})

  def timed(module, conditions, :forever, state),
    do: Map.put(timed(module, conditions, {60, 60}, state), :forever, true)

  def timed(module, conditions, {min, max}, state),
    do: %{
      kind: __MODULE__.Timed,
      impl: module,
      conditions: conditions,
      min: min,
      max: max,
      end: 0,
      forever: false,
      state: state
    }

  @doc """
  `RunOne`: `children` as `[{behavior, weight}]`, shuffled by `random`, behind
  memory `conditions` (its entry condition).
  """
  def run_one(children, random, conditions \\ []), do: gate(children, random, conditions)

  @doc """
  `GateBehavior(entry, exitErased, order, RUN_ONE)`: shuffled by `random` or
  `:ordered`, its children's first that starts runs; stopping erases `erase`.
  """
  def gate(children, random, conditions, erase \\ [], order \\ :shuffled),
    do: %{
      kind: __MODULE__.Gate,
      children:
        Enum.map(children, fn {b, w} -> %{behavior: Map.put(b, :running, false), weight: w} end),
      random: random,
      conditions: conditions,
      erase: erase,
      order: order
    }

  @doc """
  `TriggerGate.triggerOneShuffled`: a one-shot that shuffles its `triggers`
  (`[{one_shot, weight}]`) by `random` and fires them in turn until one
  starts.
  """
  def trigger_gate(triggers, random),
    do: %{
      kind: __MODULE__.TriggerGate,
      children:
        Enum.map(triggers, fn {b, w} -> %{behavior: Map.put(b, :running, false), weight: w} end),
      random: random
    }

  @doc "`DoNothing(min, max)`."
  def do_nothing(min, max), do: %{kind: __MODULE__.DoNothing, min: min, max: max, end: 0}

  @doc "A behaviour that never starts: one whose system (or memories) does not exist yet."
  def inert(name), do: %{kind: __MODULE__.Inert, name: name}

  defmodule OneShot do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(%{state: state} = b, self) do
      if Brain.conditions?(self, b.conditions) do
        {started, self, state} = b.trigger.(self, state)
        {started, %{b | running: started, state: state}, self}
      else
        {false, b, self}
      end
    end

    def try_start(b, self) do
      if Brain.conditions?(self, b.conditions) do
        {started, self} = b.trigger.(self)
        {started, %{b | running: started}, self}
      else
        {false, b, self}
      end
    end

    def tick_or_stop(b, self), do: {%{b | running: false}, self}
    def stop(b, self), do: {%{b | running: false}, self}
  end

  defmodule Timed do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(b, self) do
      if Brain.conditions?(self, b.conditions) do
        case b.impl.extra(b.state, self) do
          {true, state, self} ->
            {n, self} = Valimc.AI.Behavior.level_int(self, b.max + 1 - b.min)
            b = %{b | running: true, end: self.world.time + b.min + n}
            {state, self} = b.impl.start(state, self)
            {true, %{b | state: state}, self}

          {false, state, self} ->
            {false, %{b | state: state}, self}
        end
      else
        {false, b, self}
      end
    end

    def tick_or_stop(b, self) do
      {still, state, self} =
        if not b.forever and self.world.time > b.end,
          do: {false, b.state, self},
          else: b.impl.still(b.state, self)

      if still do
        {state, self} = b.impl.tick(state, self)
        {%{b | state: state}, self}
      else
        stop(%{b | state: state}, self)
      end
    end

    def stop(b, self) do
      {state, self} = b.impl.stop(b.state, self)
      {%{b | running: false, state: state}, self}
    end
  end

  defmodule Gate do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(b, self) do
      if Brain.conditions?(self, Map.get(b, :conditions, [])) do
        b = if Map.get(b, :order, :shuffled) == :shuffled, do: shuffle(b), else: b
        {children, self} = run_one(b.children, self, [])
        {true, %{b | running: true, children: children}, self}
      else
        {false, b, self}
      end
    end

    @doc false
    # `ShufflingList.shuffle`: each entry a random weight, sorted (stably).
    def shuffle(b) do
      {keyed, random} =
        Enum.map_reduce(b.children, b.random, fn child, random ->
          {f, random} = Valimc.AI.Random.float(random)
          exponent = Valimc.Data.Float32.round(1.0 / child.weight)
          {{-:math.pow(f, exponent), child}, random}
        end)

      %{
        b
        | children: keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)),
          random: random
      }
    end

    # `RUN_ONE`: the first stopped child that starts.
    defp run_one([], self, done), do: {Enum.reverse(done), self}

    defp run_one([child | rest], self, done) do
      if child.behavior.running do
        run_one(rest, self, [child | done])
      else
        {started, behavior, self} = child.behavior.kind.try_start(child.behavior, self)
        child = %{child | behavior: behavior}

        if started,
          do: {Enum.reverse(done, [child | rest]), self},
          else: run_one(rest, self, [child | done])
      end
    end

    def tick_or_stop(b, self) do
      {children, self} =
        Enum.map_reduce(b.children, self, fn child, self ->
          if child.behavior.running do
            {behavior, self} = child.behavior.kind.tick_or_stop(child.behavior, self)
            {%{child | behavior: behavior}, self}
          else
            {child, self}
          end
        end)

      b = %{b | children: children}
      if Enum.any?(children, & &1.behavior.running), do: {b, self}, else: stop(b, self)
    end

    def stop(b, self) do
      {children, self} =
        Enum.map_reduce(b.children, self, fn child, self ->
          if child.behavior.running do
            {behavior, self} = child.behavior.kind.stop(child.behavior, self)
            {%{child | behavior: behavior}, self}
          else
            {child, self}
          end
        end)

      self = Enum.reduce(Map.get(b, :erase, []), self, &Brain.erase(&2, &1))
      {%{b | running: false, children: children}, self}
    end
  end

  defmodule TriggerGate do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(b, self) do
      b = Valimc.AI.Behavior.Gate.shuffle(b)

      {children, self} = fire(b.children, self, [])
      {true, %{b | running: true, children: children}, self}
    end

    defp fire([], self, done), do: {Enum.reverse(done), self}

    defp fire([child | rest], self, done) do
      {started, behavior, self} = child.behavior.kind.try_start(child.behavior, self)
      child = %{child | behavior: %{behavior | running: false}}

      if started,
        do: {Enum.reverse(done, [child | rest]), self},
        else: fire(rest, self, [child | done])
    end

    def tick_or_stop(b, self), do: {%{b | running: false}, self}
    def stop(b, self), do: {%{b | running: false}, self}
  end

  defmodule DoNothing do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(b, self) do
      {n, self} = Valimc.AI.Behavior.level_int(self, b.max + 1 - b.min)
      {true, %{b | running: true, end: self.world.time + b.min + n}, self}
    end

    def tick_or_stop(b, self),
      do: if(self.world.time > b.end, do: stop(b, self), else: {b, self})

    def stop(b, self), do: {%{b | running: false}, self}
  end

  defmodule Inert do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(b, self), do: {false, b, self}
    def tick_or_stop(b, self), do: {%{b | running: false}, self}
    def stop(b, self), do: {%{b | running: false}, self}
  end
end
