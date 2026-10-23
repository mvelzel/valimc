defmodule Valimc.AI.Mobs.Phantom do
  @moduledoc """
  Phantoms (VMC-043b6), as vanilla's `Phantom`:

  - It flies (`travelFlying`, the kernel's `flying`; no input) where its
    own move control (`PhantomMoveControl`, `move_control/1`) steers it:
    turning at most four degrees a tick toward its move target, speeding up
    to 1.8 while it flies straight and slowing to 0.2 while it turns, its
    pitch toward the target, its motion easing a fifth of the way to that
    each tick; a wall turns it around. Its body faces its yaw and its head
    its last body (`PhantomBodyRotationControl`); it looks nowhere else.
  - **Goals**: its attack strategy (circle for a while above the target,
    then swoop, with the swoop sound, then circle again), the swoop (at the
    target's middle; touching it, it bites and circles again; a wall or a
    hurt breaks it off; creative and spectating players and cats end it)
    and circling its anchor (at a distance of 5 to 15 blocks and a height
    that change now and then, away from blocks above and below); as target
    the highest player it may attack within 16 blocks around and 64 up and
    down, looked for every 30 updates.
  - Its own data: its size (its box and attack, entity data), anchor, move
    target, phase and speed. It never takes fall damage.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Mth, Self, Spawn, World}
  alias Valimc.Data.Float32

  @phantom "minecraft:phantom"
  @radians Float32.round(:math.pi() / 180.0)
  @degrees Float32.round(180.0 / Float32.round(:math.pi()))

  @impl true
  def types, do: [@phantom]

  @impl true
  def goals(_type) do
    {[
       {1, "PhantomAttackStrategyGoal", __MODULE__.Strategy, [], %{next_sweep: 0}},
       {2, "PhantomSweepAttackGoal", __MODULE__.Sweep, [:move], %{scared: false, cat_search: 0}},
       {3, "PhantomCircleAroundAnchorGoal", __MODULE__.Circle, [:move],
        %{angle: 0.0, distance: 0.0, height: 0.0, clockwise: 0.0}}
     ],
     [
       {1, "PhantomAttackPlayerTargetGoal", __MODULE__.Hunt, [], %{next_scan: Mth.reduced(20)}}
     ]}
  end

  @impl true
  def motion, do: [travel: {:flying, false}]

  @impl true
  def falls?, do: false

  @impl true
  def turns_body?, do: false

  @impl true
  def data(_type),
    do: %{
      size: 0,
      anchor: nil,
      point: {0.0, 0.0, 0.0},
      phase: :circle,
      speed: Float32.round(0.1),
      ticks: 0
    }

  @impl true
  def values(%{data: data}), do: [{:phantom_size, data.size, 0}]

  @doc "`getDefaultDimensions`: its type's scaled by `1 + 0.15 * size`."
  @impl true
  def dimensions(%{type: type, data: %{size: size}}) do
    facts = Valimc.Data.EntityTypes.fetch(type)
    f = Float32.round(1.0 + Float32.round(Float32.round(0.15) * size))

    {Float32.round(Float32.round(facts.width) * f),
     Float32.round(Float32.round(facts.height) * f),
     Float32.round(Float32.round(facts.eye_height) * f)}
  end

  @doc "`finalizeSpawn`: its anchor five blocks above it, size 0, then a mob's."
  @impl true
  def finalize(%Self{data: data} = self, reason) do
    {x, y, z} = Self.block(self)
    self = %{self | data: %{data | anchor: {x, y + 5, z}, size: 0}}
    Spawn.mob(self, reason)
  end

  @doc "Its own tick count (`tickCount`, the cat search)."
  @impl true
  def tick_start(%Self{data: data} = self), do: %{self | data: %{data | ticks: data.ticks + 1}}

  @doc "`PhantomLookControl` looks nowhere; its body faces its yaw, its head its last body."
  @impl true
  def after_tick(%Self{} = self) do
    body = self.mind.body_yaw
    Self.mind(%{self | head: body}, &%{&1 | body_yaw: self.yaw})
  end

  ## The move control

  @doc "`PhantomMoveControl.tick`."
  @impl true
  def move_control(%Self{data: data} = self) do
    {self, data} =
      if self.mob.motion.horizontal_collision,
        do: {%{self | yaw: Float32.round(self.yaw + 180.0)}, %{data | speed: Float32.round(0.1)}},
        else: {self, data}

    {px, py, pz} = data.point
    tdx = px - self.x
    tdy = py - self.y
    tdz = pz - self.z
    sd = :math.sqrt(tdx * tdx + tdz * tdz)

    if abs(sd) > Float32.round(1.0e-5) do
      scale = 1.0 - abs(tdy * Float32.round(0.7)) / sd
      tdx = tdx * scale
      tdz = tdz * scale
      sd = :math.sqrt(tdx * tdx + tdz * tdz)
      sd2 = :math.sqrt(tdx * tdx + tdz * tdz + tdy * tdy)
      prev = self.yaw
      angle = Float32.round(Mth.atan2(tdz, tdx))
      a = Mth.wrap(Float32.round(self.yaw + 90.0))
      b = Mth.wrap(Float32.round(angle * @degrees))
      yaw = Float32.round(Mth.approach_degrees(a, b, 4.0) - 90.0)
      self = Self.mind(%{self | yaw: yaw}, &%{&1 | body_yaw: yaw})

      speed =
        if abs(Mth.difference(prev, yaw)) < 3.0,
          do:
            Mth.approach(
              data.speed,
              Float32.round(1.8),
              Float32.round(Float32.round(0.005) * Float32.round(Float32.round(1.8) / data.speed))
            ),
          else: Mth.approach(data.speed, Float32.round(0.2), Float32.round(0.025))

      # javac folds `180.0F / (float)Math.PI`.
      pitch = Float32.round(-(Mth.atan2(-tdy, sd) * 57.2957763671875))

      move = Float32.round(yaw + 90.0)
      cos = Valimc.Data.Mth.cos(Float32.round(move * @radians))
      sin = Valimc.Data.Mth.sin(Float32.round(move * @radians))
      psin = Valimc.Data.Mth.sin(Float32.round(pitch * @radians))
      txd = Float32.round(speed * cos) * abs(tdx / sd2)
      tzd = Float32.round(speed * sin) * abs(tdz / sd2)
      tyd = Float32.round(speed * psin) * abs(tdy / sd2)
      # Its motion after `aiStep`'s dead zone, eased a fifth of the way (the
      # kernel adds it after the dead zone).
      {vx, vy, vz} = self.velocity |> Tuple.to_list() |> Enum.map(&dead/1) |> List.to_tuple()
      impulse = {(txd - vx) * 0.2, (tyd - vy) * 0.2, (tzd - vz) * 0.2}
      motion = %{self.mob.motion | impulse: impulse}

      %{self | pitch: pitch, mob: %{self.mob | motion: motion}, data: %{data | speed: speed}}
    else
      %{self | data: data}
    end
  end

  defp dead(v), do: if(abs(v) < 0.003, do: 0.0, else: v)

  @doc "`PhantomLookControl.tick` does nothing."
  @impl true
  def looks?, do: false

  ## Shared by its goals

  @doc "Whether it may attack `target` (`TargetingConditions.DEFAULT`)."
  def attackable?(self, target) do
    World.test(self, target, World.conditions(true))
  end

  @doc "`setAnchorAboveTarget`: 20 to 39 blocks above its target, at least above sea level."
  def anchor_above_target(%Self{data: %{anchor: nil}} = self), do: self

  def anchor_above_target(%Self{data: data} = self) do
    target = World.target(self)
    {n, self} = Self.int(self, 20)
    {x, y, z} = {floor(target.x), floor(target.y) + 20 + n, floor(target.z)}
    sea = self.world.sea_level
    y = if y < sea, do: sea + 1, else: y
    %{self | data: %{data | anchor: {x, y, z}}}
  end
end

defmodule Valimc.AI.Mobs.Phantom.Hunt do
  @moduledoc """
  `PhantomAttackPlayerTargetGoal`: every 30 updates (the first after 10) the
  players within 16 blocks around and 64 up and down that it may attack
  within 64 blocks, highest first; the first it may attack becomes its
  target. It keeps one it may still attack.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Phantom

  def can_use(%{next_scan: n} = state, self) when n > 0,
    do: {false, %{state | next_scan: n - 1}, self}

  def can_use(state, self) do
    state = %{state | next_scan: Mth.reduced(60)}
    box = World.inflate(Self.box(self), 16.0, 64.0, 16.0)
    conditions = World.conditions(true, range: 64.0)

    {near, self} =
      Enum.reduce(self.world.players, {[], self}, fn p, {acc, self} ->
        if World.intersects?(World.box(p), box) do
          {ok, self} = World.test(self, p, conditions)
          {if(ok, do: acc ++ [p], else: acc), self}
        else
          {acc, self}
        end
      end)

    sorted = Enum.sort_by(near, & &1.y, :desc)

    Enum.reduce_while(sorted, {false, state, self}, fn p, {false, state, self} ->
      case Phantom.attackable?(self, p) do
        {true, self} -> {:halt, {true, state, Self.set_target(self, World.ref(p))}}
        {false, self} -> {:cont, {false, state, self}}
      end
    end)
  end

  def can_continue(state, self) do
    case World.target(self) do
      nil ->
        {false, state, self}

      target ->
        {ok, self} = Phantom.attackable?(self, target)
        {ok, state, self}
    end
  end
end

defmodule Valimc.AI.Mobs.Phantom.Strategy do
  @moduledoc """
  `PhantomAttackStrategyGoal`: while it may attack its target it circles
  above it for five updates at first, then swoops (its anchor moved above
  the target, the swoop sound) and circles again for 80 to 110 updates;
  when it stops, its anchor rises 10 to 29 blocks over the ground there.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Phantom
  alias Valimc.Data.Float32

  def can_use(state, self) do
    case World.target(self) do
      nil ->
        {false, state, self}

      target ->
        {ok, self} = Phantom.attackable?(self, target)
        {ok, state, self}
    end
  end

  def start(state, self) do
    self = %{self | data: %{self.data | phase: :circle}} |> Phantom.anchor_above_target()
    {%{state | next_sweep: Mth.reduced(10)}, self}
  end

  def stop(state, %Self{data: %{anchor: {x, _, z}}} = self) do
    {n, self} = Self.int(self, 20)
    ground = World.motion_blocking(self.world, x, z)
    {state, %{self | data: %{self.data | anchor: {x, ground + 10 + n, z}}}}
  end

  def stop(state, self), do: {state, self}

  def tick(%{next_sweep: n} = state, %Self{data: %{phase: :circle}} = self) do
    n = n - 1

    if n <= 0 do
      self = %{self | data: %{self.data | phase: :swoop}} |> Phantom.anchor_above_target()
      {k, self} = Self.int(self, 4)
      {f, self} = Self.float(self)
      pitch = Float32.round(Float32.round(0.95) + Float32.round(f * Float32.round(0.1)))
      self = Self.sound(self, "minecraft:entity.phantom.swoop", 10.0, pitch)
      {%{state | next_sweep: Mth.reduced((8 + k) * 20)}, self}
    else
      {%{state | next_sweep: n}, self}
    end
  end

  def tick(state, self), do: {state, self}
end

defmodule Valimc.AI.Mobs.Phantom.Sweep do
  @moduledoc """
  `PhantomSweepAttackGoal`: swooping at its target's middle; touching it
  (its box grown by 0.2) it bites (level event 1039) and circles again, as
  it does after hitting a wall or being hurt. A creative or spectating
  target, or a cat within 16 blocks (looked for each second), ends it, and
  its target with it.
  """
  use Valimc.AI.Goal

  def can_use(state, self),
    do: {World.target(self) != nil and self.data.phase == :swoop, state, self}

  def can_continue(state, self) do
    target = World.target(self)

    cond do
      target == nil or not target.alive ->
        {false, state, self}

      Map.get(target, :mode) in [:creative, :spectator] ->
        {false, state, self}

      true ->
        cond do
          self.data.phase != :swoop ->
            {false, state, self}

          self.data.ticks > state.cat_search ->
            box = World.inflate(Self.box(self), 16.0, 16.0, 16.0)
            cats = World.mobs_in(self, ["minecraft:cat"], box)
            state = %{state | cat_search: self.data.ticks + 20, scared: cats != []}
            {not state.scared, state, self}

          true ->
            {not state.scared, state, self}
        end
    end
  end

  def stop(state, self) do
    self = Self.set_target(self, nil)
    {state, %{self | data: %{self.data | phase: :circle}}}
  end

  def tick(state, self) do
    case World.target(self) do
      nil -> {state, self}
      target -> swoop(state, self, target)
    end
  end

  defp swoop(state, self, target) do
    point = {target.x, target.y + target.height * 0.5, target.z}
    self = %{self | data: %{self.data | point: point}}

    cond do
      World.intersects?(World.inflate(Self.box(self), 0.2, 0.2, 0.2), World.box(target)) ->
        self =
          self
          |> Self.effect({:attack, World.ref(target)})
          |> Self.effect({:level_event, Self.block(self), 1039, 0})

        {state, %{self | data: %{self.data | phase: :circle}}}

      self.mob.motion.horizontal_collision or self.mob.living.health.hurt_ticks > 0 ->
        {state, %{self | data: %{self.data | phase: :circle}}}

      true ->
        {state, self}
    end
  end
end

defmodule Valimc.AI.Mobs.Phantom.Circle do
  @moduledoc """
  `PhantomCircleAroundAnchorGoal`: with no target, or circling, it flies
  round its anchor: a distance of 5 to 15 blocks, a height of -4 to 5 and a
  direction drawn as it starts; now and then a new height, a step farther
  out (back to 5 and turning past 15) or a new angle; each new move target
  15 degrees on, and sooner when it reaches one or a block above or below
  is in its way.
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  @step Float32.round(Float32.round(15.0) * Float32.round(:math.pi() / 180.0))

  def can_use(state, self),
    do: {World.target(self) == nil or self.data.phase == :circle, state, self}

  def start(state, self) do
    {a, self} = Self.float(self)
    {b, self} = Self.float(self)
    {c, self} = Self.boolean(self)

    state = %{
      state
      | distance: Float32.round(5.0 + Float32.round(a * 10.0)),
        height: Float32.round(-4.0 + Float32.round(b * 9.0)),
        clockwise: if(c, do: 1.0, else: -1.0)
    }

    select(state, self)
  end

  def tick(state, self) do
    {n, self} = Self.int(self, Mth.reduced(350))

    {state, self} =
      if n == 0 do
        {f, self} = Self.float(self)
        {%{state | height: Float32.round(-4.0 + Float32.round(f * 9.0))}, self}
      else
        {state, self}
      end

    {n, self} = Self.int(self, Mth.reduced(250))

    state =
      if n == 0 do
        distance = Float32.round(state.distance + 1.0)

        if distance > 15.0,
          do: %{state | distance: 5.0, clockwise: -state.clockwise},
          else: %{state | distance: distance}
      else
        state
      end

    {n, self} = Self.int(self, Mth.reduced(450))

    {state, self} =
      if n == 0 do
        {f, self} = Self.float(self)
        angle = Float32.round(Float32.round(f * 2.0) * Float32.round(:math.pi()))
        select(%{state | angle: angle}, self)
      else
        {state, self}
      end

    {state, self} = if touching?(self), do: select(state, self), else: {state, self}
    {x, y, z} = Self.block(self)
    {_, py, _} = self.data.point

    {state, self} =
      if py < self.y and not World.air?(self.world, {x, y - 1, z}),
        do: select(%{state | height: max(1.0, state.height)}, self),
        else: {state, self}

    {_, py, _} = self.data.point

    if py > self.y and not World.air?(self.world, {x, y + 1, z}),
      do: select(%{state | height: min(-1.0, state.height)}, self),
      else: {state, self}
  end

  defp touching?(self) do
    {px, py, pz} = self.data.point
    {dx, dy, dz} = {px - self.x, py - self.y, pz - self.z}
    dx * dx + dy * dy + dz * dz < 4.0
  end

  # `selectNext`: the anchor its block if it has none, 15 degrees on.
  defp select(state, %Self{data: data} = self) do
    anchor = data.anchor || Self.block(self)
    angle = Float32.round(state.angle + Float32.round(state.clockwise * @step))
    {ax, ay, az} = anchor
    cos = Valimc.Data.Mth.cos(angle)
    sin = Valimc.Data.Mth.sin(angle)

    point =
      {ax + Float32.round(state.distance * cos), ay + Float32.round(-4.0 + state.height),
       az + Float32.round(state.distance * sin)}

    {%{state | angle: angle}, %{self | data: %{data | anchor: anchor, point: point}}}
  end
end
