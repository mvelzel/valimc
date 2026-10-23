defmodule Valimc.AI.Goals.Target do
  @moduledoc """
  `TargetGoal`'s common part: a target is kept while it can be attacked,
  within the follow range and, for a goal that must see it, seen at least
  once every `unseen` ticks (halved: target goals update every other tick).
  """
  alias Valimc.AI.{Mth, Self, World}

  @doc "The fields every target goal's state has."
  def fields(must_see), do: %{must_see: must_see, target: nil, unseen_ticks: 0, unseen: 60}

  @doc "`getFollowDistance`: the mob's follow range."
  def follow(%Self{} = self),
    do: Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:follow_range")

  @doc "`TargetGoal.canContinueToUse`."
  def can_continue(state, self) do
    target = World.target(self) || World.entity(self.world, state.target)
    follow = follow(self)

    cond do
      target == nil ->
        {false, state, self}

      not World.can_attack?(self, target) ->
        {false, state, self}

      World.distance_sq(self, target) > follow * follow ->
        {false, state, self}

      state.must_see ->
        case World.sees?(self, target) do
          {true, self} ->
            {true, %{state | unseen_ticks: 0}, Self.set_target(self, World.ref(target))}

          {false, self} ->
            unseen = state.unseen_ticks + 1
            state = %{state | unseen_ticks: unseen}

            if unseen > Mth.reduced(state.unseen),
              do: {false, state, self},
              else: {true, state, Self.set_target(self, World.ref(target))}
        end

      true ->
        {true, state, Self.set_target(self, World.ref(target))}
    end
  end

  @doc "`TargetGoal.start`."
  def start(state), do: %{state | unseen_ticks: 0}

  @doc "`TargetGoal.stop`."
  def stop(state, self), do: {%{state | target: nil}, Self.set_target(self, nil)}

  @doc "`TargetGoal.canAttack` with conditions (no home, no reach test)."
  def can_attack?(self, nil, _conditions), do: {false, self}
  def can_attack?(self, target, conditions), do: World.test(self, target, conditions)
end

defmodule Valimc.AI.Goals.NearestAttackableTarget do
  @moduledoc """
  `NearestAttackableTargetGoal`: by chance (one in five updates by default),
  the nearest attackable entity within the follow range, in sight, measured
  from the mob's eye: a player (`kind: :player`), a section mob whose type
  `select` takes, or either (`kind: :living`, a guardian's; its players
  within the search box) (`:selector` narrows each further).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.Target

  def new(kind, select, must_see, opts \\ []),
    do:
      Map.merge(Target.fields(must_see), %{
        kind: kind,
        select: select,
        selector: Keyword.get(opts, :selector),
        interval: Mth.reduced(Keyword.get(opts, :interval, 10)),
        peaceful: Keyword.get(opts, :peaceful, true),
        # A condition on the mob before it looks at all (a spider's
        # darkness, VMC-043b4), or nil.
        when: Keyword.get(opts, :when),
        found: nil
      })

  # Without `peaceful` (a shulker's) it looks for nothing on peaceful.
  def can_use(%{peaceful: false} = state, %Self{world: %{difficulty: :peaceful}} = self),
    do: {false, state, self}

  def can_use(%{when: condition} = state, self) when condition != nil do
    if condition.(self),
      do: can_use(%{state | when: nil}, self) |> keep(condition),
      else: {false, state, self}
  end

  def can_use(state, self) do
    {go, self} =
      if state.interval > 0 do
        {n, self} = Self.int(self, state.interval)
        {n == 0, self}
      else
        {true, self}
      end

    if go do
      {found, self} = find(state, self)
      {found != nil, %{state | found: World.ref(found)}, self}
    else
      {false, state, self}
    end
  end

  defp find(state, self) do
    follow = Target.follow(self)
    conditions = World.conditions(true, range: follow, select: state.selector)

    case state.kind do
      :player ->
        World.nearest_player(self, conditions, self.x, Self.eye_y(self), self.z)

      :mob ->
        box = World.inflate(Self.box(self), follow, follow, follow)
        World.nearest_mob(self, state.select, box, conditions, self.x, Self.eye_y(self), self.z)

      :living ->
        box = World.inflate(Self.box(self), follow, follow, follow)
        players = for p <- self.world.players, World.intersects?(World.box(p), box), do: p
        candidates = players ++ World.mobs_in(self, state.select, box)
        World.nearest(self, candidates, conditions, self.x, Self.eye_y(self), self.z)
    end
  end

  def can_continue(state, self), do: Target.can_continue(state, self)

  def start(state, self), do: {Target.start(state), Self.set_target(self, state.found)}

  defp keep({use, state, self}, condition), do: {use, %{state | when: condition}, self}

  def stop(state, self), do: Target.stop(state, self)
end

defmodule Valimc.AI.Goals.HurtByTarget do
  @moduledoc """
  `HurtByTargetGoal`: the living entity that last hurt the mob (within 100
  ticks, once per hurt) becomes its target if it can be attacked, seen or
  not; kept while seen at least every 300 ticks. With `alert`, the mob also
  sets the target of each mob of its kind within its follow range (ten
  blocks up and down) that has none (an `{:alert, mob, target}` effect).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.Target

  def new(opts \\ []),
    do:
      Map.merge(Target.fields(true), %{
        alert: Keyword.get(opts, :alert, false),
        alert_types: Keyword.get(opts, :alert_types, []),
        ignore: Keyword.get(opts, :ignore, []),
        timestamp: 0
      })

  def can_use(state, self) do
    case self.mind.hurt_by do
      {ref, timestamp} when timestamp != state.timestamp ->
        case World.entity(self.world, ref) do
          %{kind: :player} when self.world.universal_anger ->
            {false, state, self}

          nil ->
            {false, state, self}

          attacker ->
            ignored(state, self, attacker)
        end

      _ ->
        {false, state, self}
    end
  end

  # Hurt by a mob of a type it ignores (`toIgnoreDamage`), it does not turn.
  defp ignored(state, self, attacker) do
    if attacker.kind == :mob and attacker.type in state.ignore do
      {false, state, self}
    else
      conditions = World.conditions(true, sight: false, invisible: false)
      {ok, self} = Target.can_attack?(self, attacker, conditions)
      {ok, state, self}
    end
  end

  def can_continue(state, self), do: Target.can_continue(state, self)

  def start(state, self) do
    {ref, timestamp} = self.mind.hurt_by
    self = Self.set_target(self, ref)
    target = World.target(self)
    state = %{state | target: World.ref(target), timestamp: timestamp, unseen: 300}
    self = if state.alert, do: alert(state, self, ref), else: self
    {Target.start(state), self}
  end

  defp alert(state, self, attacker) do
    within = Target.follow(self)

    box =
      {self.x - within, self.y - 10.0, self.z - within, self.x + 1.0 + within,
       self.y + 1.0 + 10.0, self.z + 1.0 + within}

    self
    |> World.mobs_in(state.alert_types, box)
    |> Enum.reduce(self, fn other, self ->
      if other.uuid != self.uuid and World.entity(self.world, other.target) == nil,
        do: Self.effect(self, {:alert, other.uuid, attacker}),
        else: self
    end)
  end

  def stop(state, self), do: Target.stop(state, self)
end
