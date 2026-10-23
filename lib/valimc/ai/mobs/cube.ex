defmodule Valimc.AI.Mobs.Cube do
  @moduledoc """
  What slimes and magma cubes share (VMC-043d, vanilla's `AbstractCubeMob`);
  each cube's own module (`Valimc.AI.Mobs.MagmaCube`) builds on it.

  A cube hops: its move control (`CubeMobMoveControl`, `move_control/2`)
  turns it toward a chosen direction and, on the ground when its goals want
  movement, jumps once its jump delay runs out, with the jump sound; its
  goals float it in liquids, pick random directions, keep it jumping and
  turn it toward its target, hopping faster. Its size (entity data) scales
  its box, health and speed; landing plays its squish; a player touching a
  cube that deals damage is hurt (`playerTouch`, `touch/3`); one bigger than
  the smallest splits in two to four halves when it is removed after
  dying (`split/2`).

  Its own mind fields (`Mind.own`): the move control's direction, jump
  delay and whether it hops at a target, and the movement its goals want
  this tick. Its data: its size and whether it was on the ground.
  """
  alias Valimc.AI.{Goals, Mth, Self, Spawn, World}
  alias Valimc.Data.Float32
  alias Valimc.Entity.{Body, Mob}

  @speed "minecraft:movement_speed"

  @doc """
  `registerGoals`: floating, random directions and jumping, the cube's
  attack (`addBehaviourGoals`), then its targets: players within four
  blocks up or down, then iron golems (`addTargetingGoals`).
  """
  def goals do
    {[
       {1, "CubeMobFloatGoal", __MODULE__.Float, [:move, :jump], %{}},
       {4, "CubeMobRandomDirectionGoal", __MODULE__.RandomDirection, [:look],
        %{chosen: 0.0, next: 0}},
       {5, "CubeMobKeepOnJumpingGoal", __MODULE__.KeepOnJumping, [:move, :jump], %{}},
       {2, "CubeMobAttackGoal", __MODULE__.Attack, [:look], %{tired: 0}}
     ],
     [
       {1, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true,
          interval: 10,
          selector: &(abs(&1.y - &2.y) <= 4.0)
        )},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:iron_golem"], true)}
     ]}
  end

  @doc "A cube's data: size 1, not on the ground."
  def data, do: %{size: 1, was_on_ground: false}

  @doc "Its entity data: its size."
  def values(%{data: data}), do: [{:cube_size, data.size, 1}]

  @doc "`getDefaultDimensions`: its type's scaled by its size."
  def dimensions(%{type: type, data: %{size: size}}) do
    facts = Valimc.Data.EntityTypes.fetch(type)
    f = Float32.round(size)

    {Float32.round(Float32.round(facts.width) * f),
     Float32.round(Float32.round(facts.height) * f),
     Float32.round(Float32.round(facts.eye_height) * f)}
  end

  @doc "`getSoundVolume`: 0.4 a size."
  def volume(%{data: %{size: size}}), do: Float32.round(Float32.round(0.4) * size)

  @doc "`isTiny`."
  def tiny?(%{data: %{size: size}}), do: size <= 1

  @doc "What loot tables read of it (`type_specific/cube_mob`)."
  def loot_properties(%{data: %{size: size}}), do: [{"cube_mob/size", Integer.to_string(size)}]

  ## Size

  @doc """
  `setSize(size, true)` on a mob of `type`: its size (1 to 127), maximum
  health its square, movement speed `0.2F + 0.1F * size`, and full health;
  `more` sets the cube's own attributes (a magma cube's attack and armor).
  """
  def set_size(%Mob{} = mob, type, data, size, more) do
    size = max(1, min(size, 127))

    attributes =
      [
        {"minecraft:max_health", size * size * 1.0},
        {@speed, Float32.round(Float32.round(0.2) + Float32.round(Float32.round(0.1) * size))}
        | more.(size)
      ]
      |> Enum.reduce(mob.attributes, fn {name, base}, attributes ->
        entry = Map.get(attributes, name, %{base: nil, modifiers: []})
        Map.put(attributes, name, %{entry | base: base * 1.0})
      end)

    mob = %{mob | attributes: attributes}
    max = Mob.value(type, mob, "minecraft:max_health")
    health = %{mob.living.health | maximum: max, value: min(mob.living.health.value, max)}
    {:ok, health} = Valimc.Living.Health.set(health, max)
    {%{mob | living: %{mob.living | health: health}}, %{data | size: size}}
  end

  @doc """
  `finalizeSpawn`: the mob's own part, then `setSpawnSize` from the level's
  random: 1, 2 or 4, one step bigger by half the local difficulty's special
  multiplier.
  """
  def finalize(%Self{} = self, reason, more) do
    self = Spawn.mob(self, reason)
    {scale, self} = Spawn.level_int(self, 3)

    {scale, self} =
      if scale < 2 do
        {f, self} = Spawn.level_float(self)

        if f < Float32.round(Float32.round(0.5) * Float32.round(Spawn.special(self))),
          do: {scale + 1, self},
          else: {scale, self}
      else
        {scale, self}
      end

    {mob, data} = set_size(self.mob, self.type, self.data, Bitwise.bsl(1, scale), more)
    {width, height, eye} = dimensions(%{type: self.type, data: data})
    %{self | mob: mob, data: data, width: width, height: height, eye: eye}
  end

  ## The move control

  @own %{y_rot: 0.0, jump_delay: 0, aggressive: false, wanted: nil}

  @doc "Its move control's state."
  def own(%{own: nil}), do: @own
  def own(%{own: own}), do: own

  defp put(self, fields), do: Self.mind(self, &%{&1 | own: Map.merge(own(&1), fields)})

  @doc "`setDirection(yRot, isAggressive)`."
  def direction(self, y_rot, aggressive), do: put(self, %{y_rot: y_rot, aggressive: aggressive})

  @doc "`setWantedMovement(speedModifier)`: move this tick."
  def want(self, modifier), do: put(self, %{wanted: modifier * 1.0})

  @doc """
  `CubeMobMoveControl.tick`: it turns up to 90 degrees toward its direction,
  head and body with it. Asked to move, on the ground it hops when its jump
  delay ran out (the delay `jump_delay`'s, a third of it at a target; the
  jump sound), else stands; in the air it keeps its speed. Otherwise it
  stops its forward input.
  """
  def move_control(%Self{mob: mob} = self, jump_delay) do
    own = own(self.mind)
    yaw = Mth.rotlerp(self.yaw, own.y_rot, 90.0)
    self = Self.mind(%{self | yaw: yaw, head: yaw}, &%{&1 | body_yaw: yaw})

    case own.wanted do
      nil ->
        Self.wait(self)

      modifier ->
        self = put(self, %{wanted: nil})
        speed = Float32.round(modifier * Mob.value(self.type, mob, @speed))

        cond do
          not self.on_ground ->
            set(self, speed)

          own.jump_delay > 0 ->
            self |> put(%{jump_delay: own.jump_delay - 1}) |> set(0.0)

          true ->
            {delay, self} = jump_delay.(self)
            delay = if own.aggressive, do: div(delay, 3), else: delay
            self = self |> put(%{jump_delay: delay}) |> Self.jump()
            self |> jump_sound() |> set(speed)
        end
    end
  end

  # `setSpeed`: its speed and forward input (`MobMotion`'s `set`).
  defp set(%Self{mob: mob} = self, speed),
    do: %{self | mob: %{mob | motion: %{mob.motion | set: {speed * 1.0, false}}}}

  @doc "`getJumpDelay`: 10 to 29 ticks."
  def jump_delay(self) do
    {n, self} = Self.int(self, 20)
    {n + 10, self}
  end

  # `playSound(getJumpSound(), getSoundVolume(), getSoundPitch())`.
  defp jump_sound(self) do
    adjuster = Float32.round(if tiny?(self), do: 1.4, else: 0.8)
    {pitch, self} = pitch(self)
    sound(self, Valimc.AI.Mobs.hook(self.type, :jump_sound, [self], nil), pitch * adjuster)
  end

  # `(nextFloat() - nextFloat()) * 0.2F + 1.0F`.
  defp pitch(self) do
    {a, self} = Self.float(self)
    {b, self} = Self.float(self)
    {Float32.round(Float32.round(Float32.round(a - b) * Float32.round(0.2)) + 1.0), self}
  end

  defp sound(self, name, pitch) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    id = Valimc.AI.Facts.sound_id(name)
    source = Valimc.Protocol.CombatPackets.mob_sounds(self.type)["sound_source"]
    Self.effect(self, {:sound, id, source, volume(self), Float32.round(pitch), seed})
  end

  ## Its tick

  @doc """
  `tick()` after its super: landing, it draws its particles' places (two
  floats each, sixteen a block of its doubled width) and plays its squish;
  it remembers whether it was on the ground. Then the players touching it
  (`Player.touch`, run after the mobs) are hurt if it deals damage
  (`can_hurt`).
  """
  def after_tick(%Self{data: data} = self, can_hurt) do
    self =
      if self.on_ground and not data.was_on_ground do
        size = Float32.round(self.width * 2.0)
        bound = Float32.round(size * 16.0)
        count = if bound == trunc(bound), do: trunc(bound), else: trunc(bound) + 1

        self =
          Enum.reduce(1..count//1, self, fn _, self ->
            {_, self} = Self.float(self)
            {_, self} = Self.float(self)
            self
          end)

        {pitch, self} = pitch(self)
        name = Valimc.AI.Mobs.hook(self.type, :squish_sound, [self], nil)
        sound(self, name, Float32.round(pitch / Float32.round(0.8)))
      else
        self
      end

    self = %{self | data: %{self.data | was_on_ground: self.on_ground}}
    if can_hurt, do: touch(self), else: self
  end

  # `playerTouch` for each player whose box, a block wider and half a block
  # taller, meets it: `dealDamage`.
  defp touch(self) do
    own = Self.box(self)

    self.world.players
    |> Enum.filter(fn p ->
      p.alive and p.mode in [:survival, :adventure] and
        World.intersects?(World.inflate(World.box(p), 1.0, 0.5, 1.0), own)
    end)
    |> Enum.reduce(self, &deal_damage(&2, &1))
  end

  # `dealDamage`: within melee reach and in sight, its attack damage as a
  # mob attack, with the attack sound when it takes. The player decides
  # whether it takes; the sound's pitch is drawn as it would be.
  defp deal_damage(self, player) do
    if Valimc.AI.Behaviors.Fight.within_melee?(self, player) and
         World.line_of_sight?(self, player) do
      amount = Valimc.AI.Mobs.hook(self.type, :attack_damage, [self], 0.0)
      {pitch, self} = pitch(self)
      sound = {Valimc.AI.Facts.sound_id("minecraft:entity.slime.attack"), 1.0, pitch}
      Self.effect(self, {:touch, World.ref(player), amount, sound})
    else
      self
    end
  end

  @doc "`getAttackDamage`: its attack damage attribute."
  def attack_damage(%Self{} = self),
    do: Float32.round(Mob.value(self.type, self.mob, "minecraft:attack_damage"))

  ## Splitting

  @doc """
  `remove` of a dead cube bigger than the smallest: two to four cubes of
  half its size (its own random), each half its width off its centre on
  the diagonals and half a block up, facing a random way, at full health
  with its name, effects and AI flag (`ConversionType.SPLIT_ON_DEATH`):
  `[{body, position}]`.
  """
  def split(%Body{data: %{size: size}} = body, {x, y, z}, more) when size > 1 do
    mind = body.mob.ai
    {width, _, _} = dimensions(body)
    offset = Float32.round(width / 2.0)
    half = div(size, 2)
    {n, random} = Valimc.AI.Random.int(mind.random, 3)

    {children, _} =
      Enum.map_reduce(0..(1 + n), random, fn i, random ->
        xd = Float32.round(Float32.round(rem(i, 2) - 0.5) * offset)
        zd = Float32.round(Float32.round(div(i, 2) - 0.5) * offset)
        {f, random} = Valimc.AI.Random.float(random)
        child = child(body, half, Float32.round(f * 360.0), more)
        {{child, {x + xd, y + 0.5, z + zd}}, random}
      end)

    children
  end

  def split(_body, _position, _more), do: []

  defp child(body, size, yaw, more) do
    {:ok, new} = Body.new(body.type)
    old = body.mob
    {mob, data} = set_size(new.mob, body.type, new.data, size, more)
    living = %{mob.living | effects: old.living.effects, absorption: old.living.absorption}
    mob = %{mob | living: living, no_ai: old.no_ai, persistent: old.persistent}

    %{
      new
      | yaw: yaw,
        head_yaw: yaw,
        custom_name: body.custom_name,
        data: data,
        mob: mob
    }
  end
end

defmodule Valimc.AI.Mobs.Cube.Float do
  @moduledoc """
  `CubeMobFloatGoal`, every tick while in water or lava: it jumps four
  times in five and moves at 1.2.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Cube
  alias Valimc.Data.Float32

  def can_use(state, self), do: {Self.in_liquid?(self), state, self}
  def every_tick?(_state), do: true

  def tick(state, self) do
    {f, self} = Self.float(self)
    self = if f < Float32.round(0.8), do: Self.jump(self), else: self
    {state, Cube.want(self, 1.2)}
  end
end

defmodule Valimc.AI.Mobs.Cube.RandomDirection do
  @moduledoc """
  `CubeMobRandomDirectionGoal`, with no target while on the ground or in a
  liquid: a whole-degree direction every 40 to 99 ticks.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Cube

  def can_use(state, self) do
    {World.target(self) == nil and (self.on_ground or Self.in_liquid?(self) or levitating?(self)),
     state, self}
  end

  def tick(state, self) do
    {state, self} =
      if state.next - 1 <= 0 do
        {n, self} = Self.int(self, 60)
        {degrees, self} = Self.int(self, 360)
        {%{state | next: adjusted(state, 40 + n), chosen: degrees * 1.0}, self}
      else
        {%{state | next: state.next - 1}, self}
      end

    {state, Cube.direction(self, state.chosen, false)}
  end

  defp levitating?(self),
    do:
      Valimc.Living.Attributes.amplifier(
        self.mob.living.effects,
        Valimc.Data.EffectTypes.id("levitation")
      ) != nil
end

defmodule Valimc.AI.Mobs.Cube.KeepOnJumping do
  @moduledoc "`CubeMobKeepOnJumpingGoal`: unless it rides, it keeps moving at 1.0."
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Cube

  def can_use(state, self), do: {true, state, self}
  def tick(state, self), do: {state, Cube.want(self, 1.0)}
end

defmodule Valimc.AI.Mobs.Cube.Attack do
  @moduledoc """
  `CubeMobAttackGoal`, every tick for up to 150 ticks while it may attack
  its target: it turns toward it and hops that way, aggressively while it
  deals damage.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Cube

  def can_use(state, self) do
    case World.target(self) do
      nil -> {false, state, self}
      target -> {World.can_attack?(self, target), state, self}
    end
  end

  def can_continue(state, self) do
    case World.target(self) do
      nil ->
        {false, state, self}

      target ->
        if World.can_attack?(self, target) do
          state = %{state | tired: state.tired - 1}
          {state.tired > 0, state, self}
        else
          {false, state, self}
        end
    end
  end

  def every_tick?(_state), do: true

  def start(state, self), do: {%{state | tired: Mth.reduced(300)}, self}

  def tick(state, self) do
    self =
      case World.target(self) do
        nil -> self
        target -> Self.look_at_entity(self, target, 10.0, 10.0)
      end

    can_hurt = Valimc.AI.Mobs.hook(self.type, :deals_damage?, [self], true)
    {state, Cube.direction(self, self.yaw, can_hurt)}
  end
end
