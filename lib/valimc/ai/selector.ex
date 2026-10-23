defmodule Valimc.AI.Selector do
  @moduledoc """
  Vanilla's `GoalSelector` over a mob's goals (VMC-041a): each goal has a
  priority, control flags (`:move`, `:look`, `:jump`, `:target`) and a
  module implementing `Valimc.AI.Goal`, and is held in registration order (a tuple).

  An update tick (`tick/3`) stops running goals that cannot continue, frees
  their flags, then starts, in order, every goal that is not running, whose
  flags no running goal of the same or a lower priority number holds, and
  that can be used; a started goal stops the goals holding its flags. Then
  it ticks every running goal. Between update ticks (`tick_running/3`) only
  goals that ask to be updated every tick tick. A mob's two selectors (goals
  and targets) live in its mind as a list of goal entries and the flags
  they lock.
  """
  alias Valimc.AI.Self

  @doc "A goal entry: `{priority, module, flags, state}`, not running."
  def goal(priority, module, flags, state \\ %{}),
    do: %{priority: priority, module: module, flags: flags, state: state, running: false}

  @doc "`GoalSelector.tick`: one update of selector `which` (`:goals` or `:targets`)."
  def tick(%Self{} = self, which) do
    self = cleanup(self, which)
    self = update(self, which)
    tick_running(self, which, true)
  end

  # Stop what holds a disabled flag (VMC-043c3: a lead that broke) or
  # cannot continue.
  defp cleanup(self, which) do
    self =
      Enum.reduce(0..(tuple_size(goals(self, which)) - 1)//1, self, fn index, acc ->
        entry = elem(goals(acc, which), index)

        cond do
          not entry.running ->
            acc

          disabled?(acc, which, entry) ->
            stop(acc, which, index)

          true ->
            {continue, state, acc} = entry.module.can_continue(entry.state, acc)
            acc = put(acc, which, index, %{entry | state: state})

            if continue, do: acc, else: stop(acc, which, index)
        end
      end)

    locks = locked(self, which)
    goals = goals(self, which)

    locks =
      for {flag, index} <- locks, elem(goals, index).running, into: %{}, do: {flag, index}

    put_locks(self, which, locks)
  end

  defp update(self, which) do
    Enum.reduce(0..(tuple_size(goals(self, which)) - 1)//1, self, fn index, acc ->
      entry = elem(goals(acc, which), index)

      if not entry.running and not disabled?(acc, which, entry) and
           replaceable?(acc, which, entry) do
        {use, state, acc} = entry.module.can_use(entry.state, acc)
        acc = put(acc, which, index, %{entry | state: state})

        if use do
          acc =
            Enum.reduce(entry.flags, acc, fn flag, acc ->
              acc =
                case locked(acc, which) do
                  %{^flag => holder} -> stop(acc, which, holder)
                  _ -> acc
                end

              put_locks(acc, which, Map.put(locked(acc, which), flag, index))
            end)

          start(acc, which, index)
        else
          acc
        end
      else
        acc
      end
    end)
  end

  # `goalContainsAnyFlags(goal, disabledFlags)`: the goal selector's only.
  defp disabled?(_self, :targets, _entry), do: false
  defp disabled?(%{mind: %{disabled: []}}, :goals, _entry), do: false
  defp disabled?(%{mind: mind}, :goals, entry), do: Enum.any?(entry.flags, &(&1 in mind.disabled))

  # `goalCanBeReplacedForAllFlags`: each flag free, or held by an
  # interruptable goal of a higher priority number.
  defp replaceable?(self, which, entry) do
    locks = locked(self, which)
    goals = goals(self, which)

    Enum.all?(entry.flags, fn flag ->
      case locks do
        %{^flag => holder} ->
          holder = elem(goals, holder)
          holder.module.interruptable?(holder.state) and entry.priority < holder.priority

        _ ->
          true
      end
    end)
  end

  @doc "`tickRunningGoals`: tick running goals (all of them, or those updated every tick)."
  def tick_running(self, which, all) do
    Enum.reduce(0..(tuple_size(goals(self, which)) - 1)//1, self, fn index, acc ->
      entry = elem(goals(acc, which), index)

      if entry.running and (all or entry.module.every_tick?(entry.state)) do
        {state, acc} = entry.module.tick(entry.state, acc)
        put(acc, which, index, %{elem(goals(acc, which), index) | state: state})
      else
        acc
      end
    end)
  end

  defp start(self, which, index) do
    entry = elem(goals(self, which), index)
    self = put(self, which, index, %{entry | running: true})
    {state, self} = entry.module.start(entry.state, self)
    put(self, which, index, %{elem(goals(self, which), index) | state: state})
  end

  @doc "`WrappedGoal.stop`: stop goal `index` of selector `which` if it runs."
  def stop(self, which, index) do
    entry = elem(goals(self, which), index)

    if entry.running do
      self = put(self, which, index, %{entry | running: false})
      {state, self} = entry.module.stop(entry.state, self)
      put(self, which, index, %{elem(goals(self, which), index) | state: state})
    else
      self
    end
  end

  @doc """
  The states of selector `which`'s goals of `module` changed by `fun` (a
  hurt guardian's stroll told to go, `RandomStrollGoal.trigger`), in a
  mob's `Self` or its mind.
  """
  def change(%Self{mind: mind} = self, which, module, fun),
    do: %{self | mind: change(mind, which, module, fun)}

  def change(%Valimc.AI.Mind{} = mind, which, module, fun) do
    goals =
      mind
      |> Map.fetch!(which)
      |> Tuple.to_list()
      |> Enum.map(&if(&1.module == module, do: %{&1 | state: fun.(&1.state)}, else: &1))
      |> List.to_tuple()

    Map.put(mind, which, goals)
  end

  @doc "The running goals of selector `which`, by module, in order."
  def running(%Self{} = self, which),
    do: for(%{running: true, module: module} <- Tuple.to_list(goals(self, which)), do: module)

  defp goals(%Self{mind: mind}, :goals), do: mind.goals
  defp goals(%Self{mind: mind}, :targets), do: mind.targets

  defp locked(%Self{mind: mind}, :goals), do: mind.locked_goals
  defp locked(%Self{mind: mind}, :targets), do: mind.locked_targets

  defp put_locks(self, :goals, locks), do: Self.mind(self, &%{&1 | locked_goals: locks})
  defp put_locks(self, :targets, locks), do: Self.mind(self, &%{&1 | locked_targets: locks})

  defp put(self, :goals, index, entry),
    do: Self.mind(self, &%{&1 | goals: put_elem(&1.goals, index, entry)})

  defp put(self, :targets, index, entry),
    do: Self.mind(self, &%{&1 | targets: put_elem(&1.targets, index, entry)})
end
