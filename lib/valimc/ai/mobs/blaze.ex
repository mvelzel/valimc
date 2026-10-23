defmodule Valimc.AI.Mobs.Blaze do
  @moduledoc """
  A blaze (VMC-043d, vanilla's `Blaze`): its goals, its height offset and
  lift toward a target above it (`customServerAiStep`), and its attack
  (`BlazeAttackGoal`, `Valimc.AI.Mobs.Blaze.Attack`). It falls slowly (the
  kernel scales a falling blaze's motion, `MobMotion`), burns while charged
  (`charged?/1`, its entity data flag) and is hurt by water.

  Its own mind fields (`Mind.own`): the allowed height offset, the ticks to
  its next change, and whether it is charged.
  """
  alias Valimc.AI.{Goals, Self, World}

  @type_name "minecraft:blaze"

  @doc "The goals a blaze registers (`registerGoals`)."
  def registered do
    {[
       {4, "BlazeAttackGoal", __MODULE__.Attack, [:move, :look], __MODULE__.Attack.new()},
       {5, "MoveTowardsRestrictionGoal", Goals.Idle, [:move],
        Goals.Idle.new("MoveTowardsRestrictionGoal")},
       {7, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true, probability: 0.0)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: [@type_name])},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)}
     ]}
  end

  @doc "`getAmbientSound`."
  def ambient_sound(%Self{facts: facts}), do: facts.ambient_sound

  @doc "A fresh blaze's own fields."
  def own, do: %{offset: 0.5, next_change: 0, charged: false}

  @doc "Whether the blaze is charged (its flags' bit 0, and it shows burning)."
  def charged?(%{own: %{charged: charged}}), do: charged
  def charged?(_mind), do: false

  @doc "`setCharged`."
  def charge(%Self{} = self, charged),
    do: Self.mind(self, &%{&1 | own: %{own(&1) | charged: charged}})

  defp own(%{own: nil}), do: own()
  defp own(%{own: own}), do: own

  @doc """
  `customServerAiStep`: every 100 ticks a new height offset
  (`triangle(0.5, 6.891)`), and a lift toward a target whose eyes are higher
  than its own plus the offset.
  """
  def custom_step(%Self{} = self) do
    own = own(self.mind)
    next = own.next_change - 1

    {own, self} =
      if next <= 0 do
        {offset, self} = triangle(self, 0.5, 6.891)
        {%{own | next_change: 100, offset: Valimc.Data.Float32.round(offset)}, self}
      else
        {%{own | next_change: next}, self}
      end

    self = Self.mind(self, &%{&1 | own: own})

    case World.target(self) do
      nil ->
        self

      target ->
        if World.eye_y(target) > Self.eye_y(self) + own.offset and World.can_attack?(self, target),
          do: Self.mind(self, &%{&1 | rise: true}),
          else: self
    end
  end

  @doc "`RandomSource.triangle(mode, deviation)` of the mob's random."
  def triangle(self, mode, deviation) do
    {a, self} = Self.double(self)
    {b, self} = Self.double(self)
    {mode + deviation * (a - b), self}
  end
end

defmodule Valimc.AI.Mobs.Blaze.Attack do
  @moduledoc """
  `Blaze.BlazeAttackGoal`, updated every tick: close by (within two blocks)
  and in sight, a melee hit every 20 ticks while walking at its target;
  within the follow range and in sight, a volley: charged for 60 ticks, then
  three small fireballs six ticks apart toward the target with a spread for
  the distance, then 100 ticks' rest; out of sight, it follows for five
  ticks. A shot is the blaze's shoot event (1018) and an `{:projectile, type,
  position, velocity, rotation}` effect the owner makes a body of.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals
  alias Valimc.AI.Mobs.Blaze
  alias Valimc.Data.Float32
  alias Valimc.Entity.Projectile

  def new, do: %{attack_step: 0, attack_time: 0, last_seen: 0}

  def can_use(state, self) do
    case World.target(self) do
      %{alive: true} = target -> {World.can_attack?(self, target), state, self}
      _ -> {false, state, self}
    end
  end

  def every_tick?(_state), do: true

  def start(state, self), do: {%{state | attack_step: 0}, self}

  def stop(state, self), do: {%{state | last_seen: 0}, Blaze.charge(self, false)}

  def tick(state, self) do
    state = %{state | attack_time: state.attack_time - 1}

    case World.target(self) do
      nil -> {state, self}
      target -> attack(state, self, target)
    end
  end

  defp attack(state, self, target) do
    {seen, self} = World.sees?(self, target)
    state = %{state | last_seen: if(seen, do: 0, else: state.last_seen + 1)}
    distance = World.distance_sq(self, target)
    follow = Goals.Target.follow(self)

    cond do
      distance < 4.0 and not seen ->
        {state, self}

      distance < 4.0 ->
        {state, self} =
          if state.attack_time <= 0,
            do: {%{state | attack_time: 20}, Self.effect(self, {:attack, World.ref(target)})},
            else: {state, self}

        {state, Self.move_to(self, {target.x, target.y, target.z}, 1.0)}

      distance < follow * follow and seen ->
        {state, self} = volley(state, self, target, distance)
        {state, Self.look_at(self, {target.x, World.eye_y(target), target.z}, 10.0, 10.0)}

      state.last_seen < 5 ->
        {state, Self.move_to(self, {target.x, target.y, target.z}, 1.0)}

      true ->
        {state, self}
    end
  end

  defp volley(%{attack_time: time} = state, self, _target, _distance) when time > 0,
    do: {state, self}

  defp volley(state, self, target, distance) do
    step = state.attack_step + 1

    {state, self} =
      cond do
        step == 1 -> {%{state | attack_step: step, attack_time: 60}, Blaze.charge(self, true)}
        step <= 4 -> {%{state | attack_step: step, attack_time: 6}, self}
        true -> {%{state | attack_step: 0, attack_time: 100}, Blaze.charge(self, false)}
      end

    if state.attack_step > 1, do: {state, shoot(self, target, distance)}, else: {state, self}
  end

  # One small fireball from the blaze's middle, half a block up.
  defp shoot(self, target, distance) do
    xd = target.x - self.x
    yd = half(target) - (self.y + self.height * 0.5)
    zd = target.z - self.z
    spread = :math.sqrt(:math.sqrt(distance)) * 0.5
    {x, self} = Blaze.triangle(self, xd, 2.297 * spread)
    {z, self} = Blaze.triangle(self, zd, 2.297 * spread)
    {dx, dy, dz} = Projectile.normalize(Projectile.normalize({x, yd, z}))
    position = {self.x, self.y + self.height * 0.5 + 0.5, self.z}

    self
    |> Self.effect({:level_event, Self.block(self), 1018, 0})
    |> Self.effect(
      {:projectile, "minecraft:small_fireball", position, {dx * 0.1, dy * 0.1, dz * 0.1},
       {Float32.round(self.yaw), Float32.round(self.pitch)}}
    )
  end

  defp half(target), do: target.y + target.height * 0.5
end
