defmodule Valimc.AI.Mobs.Ghast do
  @moduledoc """
  A ghast (VMC-043d, vanilla's `Ghast`): it flies (`travelFlying`, the
  kernel's `flying`) with its own move control (`GhastMoveControl`, the
  kernel's `float`), wanders to random places within 16 blocks
  (`RandomFloatAroundGoal`), faces where it drifts or its target
  (`GhastLookGoal`) and, at a player within 64 blocks it sees, charges for
  a second and shoots a large fireball (`GhastShootFireballGoal`), then
  rests two seconds. It targets players no more than four blocks above or
  below it. Its own data: whether it is charging (entity data) and its
  explosion power.
  """
  @behaviour Valimc.AI.Kind

  alias Valimc.AI.{Goals, Self, World}
  alias Valimc.Data.Float32

  @ghast "minecraft:ghast"

  @impl true
  def types, do: [@ghast]

  @impl true
  def goals(_type) do
    {[
       {5, "RandomFloatAroundGoal", __MODULE__.FloatAround, [:move], %{}},
       {7, "GhastLookGoal", __MODULE__.Look, [:look], %{}},
       {7, "GhastShootFireballGoal", __MODULE__.Shoot, [], __MODULE__.Shoot.new()}
     ],
     [
       {1, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true,
          interval: 10,
          selector: &(abs(&1.y - &2.y) <= 4.0)
        )}
     ]}
  end

  @impl true
  def data(_type), do: %{charging: false, power: 1}

  @impl true
  def values(%{data: data}), do: [{:ghast_charging, data.charging, false}]

  @impl true
  def motion, do: [travel: {:flying, false}]

  @doc """
  `Ghast.hurtServer`: a large fireball a player sent back (`isReflectedFireball`)
  hurts for 1000, fire immunity aside (`isInvulnerableTo`).
  """
  @impl true
  def taken(_body, %{direct: %{type: "minecraft:fireball"}, attacker: %{player: true}} = hit),
    do: Map.merge(hit, %{amount: 1000.0, bypass_immunity: true})

  def taken(_body, hit), do: hit

  @doc "Its move control: what it wants and when it next pushes (nil before any)."
  def float(%Self{mob: mob}), do: mob.motion.float || %{wanted: nil, duration: 0}

  @doc "`MoveControl.setWantedPosition` on a ghast's move control."
  def want(%Self{mob: mob} = self, {x, y, z}) do
    float = %{float(self) | wanted: {x * 1.0, y * 1.0, z * 1.0}}
    %{self | mob: %{mob | motion: %{mob.motion | float: float}}}
  end

  @doc "`setCharging`."
  def charging(%Self{data: data} = self, charging),
    do: %{self | data: %{data | charging: charging}}
end

defmodule Valimc.AI.Mobs.Ghast.FloatAround do
  @moduledoc """
  `Ghast.RandomFloatAroundGoal`: with no place wanted, or one less than a
  block or more than 60 away, a random place within 16 blocks on each axis
  (three floats of its random). It runs for one tick.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Ghast
  alias Valimc.Data.Float32

  def can_use(state, self) do
    case Ghast.float(self).wanted do
      nil ->
        {true, state, self}

      {wx, wy, wz} ->
        {dx, dy, dz} = {wx - self.x, wy - self.y, wz - self.z}
        d = dx * dx + dy * dy + dz * dz
        {d < 1.0 or d > 3600.0, state, self}
    end
  end

  def can_continue(state, self), do: {false, state, self}

  # `getSuitableFlyToPosition(mob, 0)`: with no distance to blocks asked
  # for, the first place is good (the heightmap's mirror below only follows
  # 64 failed tries).
  def start(state, self) do
    {x, self} = offset(self, self.x)
    {y, self} = offset(self, self.y)
    {z, self} = offset(self, self.z)
    {state, Ghast.want(self, {x, y, z})}
  end

  # `center + (nextFloat() * 2 - 1) * 16`, in floats.
  defp offset(self, center) do
    {f, self} = Self.float(self)
    {center + Float32.round(Float32.round(Float32.round(f * 2.0) - 1.0) * 16.0), self}
  end
end

defmodule Valimc.AI.Mobs.Ghast.Look do
  @moduledoc """
  `Ghast.GhastLookGoal`, every tick (`faceMovementDirection`): with no
  target it turns, body too, to where it drifts; with one within 64 blocks
  it turns toward it.
  """
  use Valimc.AI.Goal

  @degrees 57.2957763671875

  def can_use(state, self), do: {true, state, self}
  def every_tick?(_state), do: true

  def tick(state, self) do
    case World.target(self) do
      nil ->
        # Its motion as `aiStep` left it before the goals: tiny parts zeroed.
        {vx, _, vz} = self.velocity
        {state, face(self, Mth.atan2(dead(vx), dead(vz)))}

      target ->
        if World.distance_sq(self, target) < 4096.0,
          do: {state, face(self, Mth.atan2(target.x - self.x, target.z - self.z))},
          else: {state, self}
    end
  end

  defp dead(v) when abs(v) < 0.003, do: 0.0
  defp dead(v), do: v

  # `setYRot(-((float)atan2) * (180F / PI))` and the body with it.
  defp face(self, angle) do
    yaw = Valimc.Data.Float32.round(-Valimc.Data.Float32.round(angle) * @degrees)
    Self.mind(%{self | yaw: yaw}, &%{&1 | body_yaw: yaw})
  end
end

defmodule Valimc.AI.Mobs.Ghast.Shoot do
  @moduledoc """
  `Ghast.GhastShootFireballGoal`, every tick while it has a target: within
  64 blocks and in its sight it charges (the warning event 1015 at ten
  ticks); at twenty it shoots a large fireball from four blocks before it
  toward the target's middle (event 1016) and waits forty ticks; out of
  sight the charge runs down. It shows charging past ten ticks.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Ghast
  alias Valimc.Data.Float32

  def new, do: %{charge: 0}

  def can_use(state, self), do: {World.target(self) != nil, state, self}
  def every_tick?(_state), do: true

  def start(state, self), do: {%{state | charge: 0}, self}
  def stop(state, self), do: {state, Ghast.charging(self, false)}

  def tick(state, self) do
    case World.target(self) do
      nil ->
        {state, self}

      target ->
        {state, self} =
          if World.distance_sq(self, target) < 4096.0 and World.line_of_sight?(self, target) do
            charge(%{state | charge: state.charge + 1}, self, target)
          else
            {%{state | charge: if(state.charge > 0, do: state.charge - 1, else: state.charge)},
             self}
          end

        {state, Ghast.charging(self, state.charge > 10)}
    end
  end

  defp charge(%{charge: 10} = state, self, _target),
    do: {state, Self.effect(self, {:level_event, Self.block(self), 1015, 0})}

  defp charge(%{charge: 20} = state, self, target),
    do: {%{state | charge: -40}, shoot(self, target)}

  defp charge(state, self, _target), do: {state, self}

  # A large fireball four blocks before its face, toward the target's middle.
  defp shoot(self, target) do
    {vx, _, vz} = view(self)
    half = self.y + self.height * 0.5
    xd = target.x - (self.x + vx * 4.0)
    yd = target.y + target.height * 0.5 - (0.5 + half)
    zd = target.z - (self.z + vz * 4.0)

    {dx, dy, dz} =
      Valimc.Entity.Projectile.normalize(Valimc.Entity.Projectile.normalize({xd, yd, zd}))

    position = {self.x + vx * 4.0, half + 0.5, self.z + vz * 4.0}

    self
    |> Self.effect({:level_event, Self.block(self), 1016, 0})
    |> Self.effect(
      {:projectile, "minecraft:fireball", position, {dx * 0.1, dy * 0.1, dz * 0.1},
       {Float32.round(self.yaw), Float32.round(self.pitch)}}
    )
  end

  # `getViewVector(1)`: a living entity looks along its head
  # (`calculateViewVector(xRot, yHeadRot)`), in floats.
  defp view(self) do
    radians = Float32.round(:math.pi() / 180.0)
    f = Float32.round(self.pitch * radians)
    g = Float32.round(-self.head * radians)
    h = Valimc.Data.Mth.cos(g)
    i = Valimc.Data.Mth.sin(g)
    j = Valimc.Data.Mth.cos(f)
    k = Valimc.Data.Mth.sin(f)
    {Float32.round(i * j) * 1.0, -k * 1.0, Float32.round(h * j) * 1.0}
  end
end
