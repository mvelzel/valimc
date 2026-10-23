defmodule Valimc.AI.Goals.MeleeAttack do
  @moduledoc """
  `MeleeAttackGoal` (and `ZombieAttackGoal`, `raise_arms`): with a living
  target it can path to or reach, at most once a second, it walks to the
  target (a new path every 4 to 10 ticks when the target moved or by chance,
  later far away), looks at it, and hits it through `Mob.doHurtTarget`
  (VMC-037n) when its cooldown is over, the target is within reach of its
  box and in sight: a swing and an `{:attack, target}` effect. A zombie
  raises its arms five ticks in, while its next hit is less than half a
  cooldown away.
  """
  use Valimc.AI.Goal

  @reach :math.sqrt(Valimc.Data.Float32.round(2.04)) - Valimc.Data.Float32.round(0.6)
  @chance Valimc.Data.Float32.round(0.05)

  def new(speed, follow_unseen, opts \\ []),
    do: %{
      speed: speed * 1.0,
      follow_unseen: follow_unseen,
      raise_arms: Keyword.get(opts, :raise_arms, false),
      path: nil,
      pathed: {0.0, 0.0, 0.0},
      recalculate: 0,
      cooldown: 0,
      last_check: 0,
      arms: 0
    }

  def can_use(state, self) do
    time = self.world.time

    if time - state.last_check < 20 do
      {false, state, self}
    else
      state = %{state | last_check: time}

      case World.target(self) do
        %{alive: true} = target ->
          {path, self} = Navigation.path_to_entity(self, target, 0)
          {path != nil or within_reach?(self, target), %{state | path: path}, self}

        _ ->
          {false, state, self}
      end
    end
  end

  def can_continue(state, self) do
    case World.target(self) do
      %{alive: true} = target ->
        if state.follow_unseen do
          {target.kind != :player or target.mode not in [:spectator, :creative], state, self}
        else
          {not Navigation.done?(self.mind.navigation), state, self}
        end

      _ ->
        {false, state, self}
    end
  end

  def start(state, self) do
    {_, self} = Navigation.follow(self, state.path, state.speed)
    self = Self.set_aggressive(self, true)
    {%{state | recalculate: 0, cooldown: 0, arms: 0}, self}
  end

  def stop(state, self) do
    self = self |> Self.set_aggressive(false) |> Navigation.stop()
    {state, self}
  end

  def every_tick?(_state), do: true

  def tick(state, self) do
    {state, self} =
      case World.target(self) do
        nil -> {state, self}
        target -> chase(state, self, target)
      end

    if state.raise_arms do
      arms = state.arms + 1
      raised = arms >= 5 and state.cooldown < div(adjusted(state, 20), 2)
      {%{state | arms: arms}, Self.set_aggressive(self, raised)}
    else
      {state, self}
    end
  end

  defp chase(state, self, target) do
    self = Self.look_at(self, {target.x, World.eye_y(target), target.z}, 30.0, 30.0)
    state = %{state | recalculate: max(state.recalculate - 1, 0)}

    {seen, self} =
      if state.follow_unseen, do: {true, self}, else: World.sees?(self, target)

    {state, self} =
      if seen and state.recalculate <= 0 do
        {repath, self} = repath?(state, self, target)
        if repath, do: repath(state, self, target), else: {state, self}
      else
        {state, self}
      end

    state = %{state | cooldown: max(state.cooldown - 1, 0)}
    attack(state, self, target)
  end

  defp repath?(%{pathed: {px, py, pz}}, self, target) do
    {dx, dy, dz} = {target.x - px, target.y - py, target.z - pz}

    if (px == 0.0 and py == 0.0 and pz == 0.0) or dx * dx + dy * dy + dz * dz >= 1.0 do
      {true, self}
    else
      {f, self} = Self.float(self)
      {f < @chance, self}
    end
  end

  defp repath(state, self, target) do
    {n, self} = Self.int(self, 7)
    recalculate = 4 + n
    distance = World.distance_sq(self, target)

    recalculate =
      cond do
        distance > 1024.0 -> recalculate + 10
        distance > 256.0 -> recalculate + 5
        true -> recalculate
      end

    {moved, self} = Navigation.move_to_entity(self, target, state.speed, 0)
    recalculate = if moved, do: recalculate, else: recalculate + 15

    {%{state | pathed: {target.x, target.y, target.z}, recalculate: adjusted(state, recalculate)},
     self}
  end

  defp attack(state, self, target) do
    if state.cooldown <= 0 and within_reach?(self, target) do
      case World.sees?(self, target) do
        {true, self} ->
          self = self |> Self.effect(:swing) |> Self.effect({:attack, World.ref(target)})
          {%{state | cooldown: adjusted(state, 20)}, self}

        {false, self} ->
          {state, self}
      end
    else
      {state, self}
    end
  end

  @doc "`Mob.isWithinMeleeAttackRange`: its box widened by its reach meets the target's."
  def within_reach?(self, target),
    do: World.intersects?(World.inflate(Self.box(self), @reach, 0.0, @reach), World.box(target))
end
