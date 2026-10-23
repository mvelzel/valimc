defmodule Valimc.AI.Brain do
  @moduledoc """
  Vanilla's `Brain` (VMC-041a2): memories with expiry, sensors with their
  scan rates, activities (a core set always active and one other, chosen by
  the memories each requires) and behaviours by priority.

  `tick/1` is `Brain.tick`: memories age (one that has run out is cleared),
  each sensor whose countdown ends scans, every stopped behaviour of an
  active activity tries to start (by priority, then activity, then order),
  and every running behaviour ticks or stops. A behaviour is a map whose
  `:kind` module implements `Valimc.AI.Behavior`.

  Memories are `%{name => {value, ttl}}`, `ttl` a count of ticks or
  `:never`. `order` is the activity order it was made with, and `refresh`
  the gate randoms a brain made again takes in turn (an oracle's). Entities are kept by reference (`World.ref/1`) and read through
  the world each tick, as vanilla's memories hold live entities.
  """
  alias Valimc.AI.{Random, Self}

  defstruct module: nil,
            memories: %{},
            sensors: [],
            activities: [],
            behaviors: {},
            core: [:core],
            active: [:core],
            default: :idle,
            schedule_update: -9999,
            order: %{},
            refresh: nil

  @doc """
  A brain of mob module `module` (its activity choice, ambient sound and
  looting) with `sensors` (`[{module, scan_rate}]`, their countdowns drawn
  from `random` as `Sensor.randomlyDelayStart` does) and `activities`
  (`[{activity, first_priority, [behavior], requirements, erase}]`, each
  behaviour at the next priority, or `first_priority` `:each` and
  `[{priority, behavior}]`). Behaviours of one priority run by activity in
  `order` (`%{priority => [activity]}`, vanilla's hash order; by default the
  order of `activities`), then in their activity's order.
  `{brain, random}`.
  """
  def new(module, sensors, activities, random, order \\ %{}) do
    {sensors, random} =
      Enum.map_reduce(sensors, random, fn {module, scan}, random ->
        {time, random} = Random.int(random, scan)
        {%{module: module, scan: scan, time: time}, random}
      end)

    behaviors =
      for {{activity, first, list, _, _}, a} <- Enum.with_index(activities),
          {entry, i} <- Enum.with_index(list) do
        {priority, behavior} = if(first == :each, do: entry, else: {first + i, entry})
        rank = order |> Map.get(priority, []) |> Enum.find_index(&(&1 == activity))

        {{priority, rank || a, i},
         Map.merge(behavior, %{activity: activity, priority: priority, running: false})}
      end

    behaviors = behaviors |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    activities =
      for {activity, _, _, requirements, erase} <- activities,
          do: %{name: activity, requirements: requirements, erase: erase}

    brain = %__MODULE__{
      module: module,
      sensors: sensors,
      activities: activities,
      behaviors: List.to_tuple(behaviors),
      order: order
    }

    {use_default(brain), random}
  end

  ## Memories

  @doc "The value of memory `name`, or nil."
  def get(%Self{mind: %{brain: brain}}, name), do: memory(brain, name)

  defp memory(%__MODULE__{memories: memories}, name) do
    case memories do
      %{^name => {value, _}} -> value
      _ -> nil
    end
  end

  @doc "Whether memory `name` holds a value."
  def has?(self, name), do: get(self, name) != nil

  @doc "The ticks memory `name` has left, `:never`, or nil without a value."
  def ttl(%Self{mind: %{brain: brain}}, name) do
    case brain.memories do
      %{^name => {_, ttl}} -> ttl
      _ -> nil
    end
  end

  @doc "`setMemory`: an empty list or nil erases."
  def set(self, name, value), do: set(self, name, value, :never)

  @doc "`setMemoryWithExpiry`."
  def set(self, name, value, _ttl) when value in [nil, []], do: erase(self, name)

  def set(self, name, value, ttl),
    do: put(self, &%{&1 | memories: Map.put(&1.memories, name, {value, ttl})})

  @doc "`eraseMemory`."
  def erase(self, name), do: put(self, &%{&1 | memories: Map.delete(&1.memories, name)})

  defp put(%Self{mind: %{brain: brain} = mind} = self, fun),
    do: %{self | mind: %{mind | brain: fun.(brain)}}

  @doc "Check memory conditions: `[{name, :present | :absent | :registered}]`."
  def conditions?(self, conditions) do
    Enum.all?(conditions, fn
      {name, :present} -> has?(self, name)
      {name, :absent} -> not has?(self, name)
      {_name, :registered} -> true
    end)
  end

  ## Activities

  @doc "Whether `activity` is active."
  def active?(%Self{mind: %{brain: brain}}, activity), do: activity in brain.active

  @doc "`getActiveNonCoreActivity`."
  def activity(%Self{mind: %{brain: brain}}),
    do: Enum.find(brain.active, &(&1 not in brain.core))

  @doc "`setActiveActivityIfPossible`: the activity when its requirements hold, else the default."
  def set_active_if_possible(self, activity) do
    if requirements_met?(self, activity),
      do: put(self, &activate(&1, activity)),
      else: put(self, &activate(&1, &1.default))
  end

  @doc "`setDefaultActivity`."
  def set_default(self, activity), do: put(self, &%{&1 | default: activity})

  @doc """
  `updateActivityFromSchedule`: at most once in 20 ticks, the scheduled
  activity (`scheduled`, an atom) when it is not active.
  """
  def update_from_schedule(%Self{mind: %{brain: brain}, world: world} = self, scheduled) do
    if world.time - brain.schedule_update > 20 do
      self = put(self, &%{&1 | schedule_update: world.time})

      if active?(self, scheduled), do: self, else: set_active_if_possible(self, scheduled)
    else
      self
    end
  end

  @doc "`setActiveActivityToFirstValid`."
  def first_valid(self, activities) do
    case Enum.find(activities, &requirements_met?(self, &1)) do
      nil -> self
      activity -> put(self, &activate(&1, activity))
    end
  end

  defp requirements_met?(%Self{mind: %{brain: brain}} = self, activity) do
    case Enum.find(brain.activities, &(&1.name == activity)) do
      nil -> false
      %{requirements: requirements} -> conditions?(self, requirements)
    end
  end

  defp use_default(brain), do: activate(brain, brain.default)

  # `setActiveActivity`: a newly active activity erases what the others it
  # replaces erase when they stop.
  defp activate(brain, activity) do
    if activity in brain.active do
      brain
    else
      erased =
        for old <- brain.active,
            old != activity,
            %{erase: erase} <- Enum.filter(brain.activities, &(&1.name == old)),
            name <- erase,
            do: name

      %{brain | memories: Map.drop(brain.memories, erased), active: brain.core ++ [activity]}
    end
  end

  ## Ticking

  @doc "`Brain.tick`."
  def tick(%Self{} = self) do
    self = put(self, &forget/1)
    self = sensors(self)
    self = start_stopped(self)
    tick_running(self)
  end

  # `MemorySlot.tick`: a memory that has run out is cleared, else counts down.
  defp forget(brain) do
    memories =
      for {name, {value, ttl}} <- brain.memories,
          ttl == :never or ttl > 0,
          into: %{},
          do: {name, {value, if(ttl == :never, do: :never, else: ttl - 1)}}

    %{brain | memories: memories}
  end

  defp sensors(%Self{mind: %{brain: brain}} = self) do
    Enum.reduce(0..(length(brain.sensors) - 1)//1, self, fn index, self ->
      sensor = Enum.at(self.mind.brain.sensors, index)
      time = sensor.time - 1

      if time <= 0 do
        self = put_sensor(self, index, %{sensor | time: sensor.scan})
        sensor.module.scan(self)
      else
        put_sensor(self, index, %{sensor | time: time})
      end
    end)
  end

  defp put_sensor(self, index, sensor),
    do: put(self, &%{&1 | sensors: List.replace_at(&1.sensors, index, sensor)})

  defp start_stopped(self) do
    Enum.reduce(0..(tuple_size(self.mind.brain.behaviors) - 1)//1, self, fn index, self ->
      behavior = elem(self.mind.brain.behaviors, index)

      if not behavior.running and active?(self, behavior.activity) do
        {_, behavior, self} = behavior.kind.try_start(behavior, self)
        put_behavior(self, index, behavior)
      else
        self
      end
    end)
  end

  defp tick_running(self) do
    Enum.reduce(0..(tuple_size(self.mind.brain.behaviors) - 1)//1, self, fn index, self ->
      behavior = elem(self.mind.brain.behaviors, index)

      if behavior.running do
        {behavior, self} = behavior.kind.tick_or_stop(behavior, self)
        put_behavior(self, index, behavior)
      else
        self
      end
    end)
  end

  defp put_behavior(self, index, behavior),
    do: put(self, &%{&1 | behaviors: put_elem(&1.behaviors, index, behavior)})

  @doc "The running behaviours as `priority:activity`, in tick order (for checks)."
  def running(%Self{mind: %{brain: brain}}) do
    for b <- Tuple.to_list(brain.behaviors), b.running, do: "#{b.priority}:#{b.activity}"
  end
end
