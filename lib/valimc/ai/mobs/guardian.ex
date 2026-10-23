defmodule Valimc.AI.Mobs.Guardian do
  @moduledoc """
  Guardians and elder guardians (`Guardian`, `ElderGuardian`). A guardian
  swims to random spots in water (now and then, or at once after a hurt or
  a beam), steered by its own move control: it eases its speed toward the
  wanted one, turns at most 90 degrees a tick, bobs as it goes and looks a
  little ahead. It travels in water at a tenth of its input with 0.9 drag,
  sinking slowly while still with no target, and flops about on land.

  It targets players, squid and axolotls it sees more than three blocks
  away and beams one (`Attack`): standing still and looking at it, after
  ten ticks it shows the beam (its attack target data, entity event 21) and
  after its attack duration (80 ticks, an elder's 60) it hits with magic (1,
  plus 2 on hard and 2 for an elder) and its melee attack, then lets go and
  swims off. A hit from a living attacker while it is still pricks the
  attacker with two thorns damage (on its next tick).

  An elder never despawns, strolls a fifth as often, takes a home of 16
  blocks where it first ticks (`Mob.home`, `Goals.MoveTowardsRestriction`
  brings it back), and every minute curses players within 50 blocks with
  Mining Fatigue III (`{:elder_curse, at}`).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Mth, Navigation, Selector, Self, World}
  alias Valimc.Data.Float32

  @guardian "minecraft:guardian"
  @elder "minecraft:elder_guardian"
  @spread Float32.round(0.4)
  @lerp Float32.round(0.125)
  @radians Float32.round(:math.pi() / 180.0)

  @impl true
  def types, do: [@guardian, @elder]

  @impl true
  def goals(type) do
    elder = type == @elder

    {[
       {4, "GuardianAttackGoal", __MODULE__.Attack, [:move, :look], __MODULE__.Attack.new(elder)},
       {5, "MoveTowardsRestrictionGoal", Goals.MoveTowardsRestriction, [:move, :look],
        Goals.MoveTowardsRestriction.new(1.0)},
       {7, "RandomStrollGoal", Goals.RandomStroll, [:move, :look],
        Goals.RandomStroll.new(1.0, interval: if(elder, do: 400, else: 80))},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look],
        Goals.LookAtPlayer.new(12.0, 0.01, types: [@guardian, @elder])},
       {9, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:living, &prey?/1, true, selector: &far?/2)}
     ]}
  end

  @prey ~w(minecraft:squid minecraft:glow_squid minecraft:axolotl)

  # `GuardianAttackSelector`: a player, squid or axolotl more than three
  # blocks away.
  defp prey?(type), do: type in @prey
  defp far?(target, self), do: World.distance_sq(self, target) > 9.0

  @impl true
  def navigation, do: {:water, []}

  @impl true
  # Its travel when its AI does not choose one (dead, `NoAI`): no target.
  def motion, do: [emission: :events, travel: {:guardian, true}]

  @impl true
  def data(_type), do: %{moving: false, beam: 0}

  @impl true
  def values(%{data: data}),
    do: [{:guardian_moving, data.moving, false}, {:guardian_attack_target, data.beam, 0}]

  @doc "An elder guardian never despawns (`setPersistenceRequired`)."
  @impl true
  def finalize(%Self{type: @elder} = self, reason),
    do: Valimc.AI.Spawn.mob(%{self | mob: %{self.mob | persistent: true}}, reason)

  def finalize(self, reason), do: Valimc.AI.Spawn.mob(self, reason)

  # ---- sounds

  @impl true
  def ambient_sound(%Self{type: type} = self),
    do: sound_name(type, "ambient", Self.in_water?(self))

  @doc "Its hurt and death sounds, in water or on land."
  @impl true
  def sound(%{type: type, mob: mob}, "hurt_sound"),
    do: sound_name(type, "hurt", mob.motion.water > 0.0)

  def sound(%{type: type, mob: mob}, "death_sound"),
    do: sound_name(type, "death", mob.motion.water > 0.0)

  def sound(_body, _which), do: nil

  defp sound_name("minecraft:" <> name, sound, true), do: "minecraft:entity.#{name}.#{sound}"

  defp sound_name("minecraft:" <> name, sound, false),
    do: "minecraft:entity.#{name}.#{sound}_land"

  @doc "`getWalkTargetValue`: water above all, then darkness."
  @impl true
  def walk_value(%Self{world: world}, pos) do
    cost = Float32.round(World.light(world, pos) - 0.5)
    if World.fluid(world, pos) == :water, do: Float32.round(10.0 + cost), else: -cost
  end

  # ---- its tick

  @doc "Thorns it owes the attackers that hit it still (`hurtServer`)."
  @impl true
  def tick_start(%Self{mind: %{own: %{thorns: [_ | _] = thorns}}} = self) do
    self = Self.mind(self, &%{&1 | own: %{&1.own | thorns: []}})
    Enum.reduce(thorns, self, &Self.effect(&2, {:hurt, &1, :thorns, 2.0, []}))
  end

  def tick_start(self), do: self

  @doc """
  `Guardian.aiStep` before its super: full air in water; on land, a flop
  up with a random sideways push and a random facing; while beaming, its
  body faces where its head looks.
  """
  @impl true
  def before_ai(%Self{} = self) do
    self =
      cond do
        Self.in_water?(self) ->
          %{self | mob: %{self.mob | living: %{self.mob.living | air_supply: 300}}}

        self.on_ground ->
          {a, self} = Self.float(self)
          {b, self} = Self.float(self)
          side = &Float32.round(Float32.round(Float32.round(&1 * 2.0) - 1.0) * @spread)
          {vx, vy, vz} = self.velocity
          {f, self} = Self.float(self)

          %{
            self
            | velocity: {vx + side.(a), vy + 0.5, vz + side.(b)},
              yaw: Float32.round(f * 360.0),
              on_ground: false
          }

        true ->
          self
      end

    if self.data.beam != 0, do: %{self | yaw: self.head}, else: self
  end

  @doc """
  `ElderGuardian.customServerAiStep`: every 1200 ticks (by its tick and
  id) its curse, and a home where it first ticks.
  """
  @impl true
  def custom_step(%Self{type: @elder} = self) do
    self =
      if rem(self.mind.tick + self.id, 1200) == 0,
        do: Self.effect(self, {:elder_curse, {self.x, self.y, self.z}}),
        else: self

    if self.mob.home,
      do: self,
      else: %{self | mob: %{self.mob | home: {{floor(self.x), floor(self.y), floor(self.z)}, 16}}}
  end

  def custom_step(self), do: self

  @doc """
  `GuardianMoveControl.tick`: toward the wanted position while it
  navigates (turning, easing its speed, a bob along its heading and up
  toward the target, its look led an eighth of the way ahead), else still.
  It travels as a guardian, sinking while still with no target.
  """
  @impl true
  def move_control(%Self{mob: mob} = self) do
    self =
      case mob.motion.control do
        {:move_to, wanted, modifier} ->
          if Navigation.done?(self.mind.navigation),
            do: still(self),
            else: steer(self, wanted, modifier)

        _ ->
          still(self)
      end

    sink = not self.data.moving and self.mind.target == nil
    travel = {:guardian, sink}
    %{self | mob: %{self.mob | motion: %{self.mob.motion | travel: travel}}}
  end

  defp still(self), do: set(%{self | data: %{self.data | moving: false}}, 0.0, {0.0, 0.0, 0.0})

  defp steer(self, {wx, wy, wz}, modifier) do
    {dx, dy, dz} = {wx - self.x, wy - self.y, wz - self.z}
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {xd, yd, zd} = {dx / length, dy / length, dz / length}
    yaw = Mth.rotlerp(self.yaw, Mth.yaw(dx, dz), 90.0)
    self = Self.mind(%{self | yaw: yaw}, &%{&1 | body_yaw: yaw})

    attribute = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:movement_speed")
    target = Float32.round(modifier * attribute)
    speed = Mth.lerp(@lerp, Self.speed(self), target)

    # `Math.sin` and `cos` as vanilla's (`StrictMath`).
    t = self.mind.tick + self.id
    push = sin(t * 0.5) * 0.05
    {s, c} = Valimc.Native.physics_sin_cos(Float32.round(yaw * @radians))
    y_push = sin(t * 0.75) * 0.05
    impulse = {push * c, y_push * (s + c) * 0.25 + speed * yd * 0.1, push * s}

    new = {self.x + xd * 2.0, Self.eye_y(self) + yd / length, self.z + zd * 2.0}

    old =
      case self.mind.look do
        %{cooldown: cooldown, x: x, y: y, z: z} when cooldown > 0 -> {x, y, z}
        _ -> new
      end

    # `Mth.lerp(0.125, old, new)` in doubles.
    look = Enum.zip_with(Tuple.to_list(old), Tuple.to_list(new), &(&1 + 0.125 * (&2 - &1)))

    self
    |> Self.look_at(List.to_tuple(look), 10.0, 40.0)
    |> Map.update!(:data, &%{&1 | moving: true})
    |> set(speed, impulse)
  end

  defp sin(x), do: elem(Valimc.Native.physics_sin_cos(x), 0)

  # `setSpeed` (no lift) and the move control's push.
  defp set(%Self{mob: mob} = self, speed, impulse) do
    motion = %{mob.motion | set: {speed * 1.0, false}, impulse: impulse}
    %{self | mob: %{mob | motion: motion}}
  end

  # ---- hurts

  @doc """
  `Guardian.hurtServer`: a living attacker that hit it while still takes
  thorns (on its next tick), and its stroll goes at once.
  """
  @impl true
  def hurt(%{data: data, mob: %{ai: %Valimc.AI.Mind{} = mind} = mob} = body, hit) do
    mind = Selector.change(mind, :goals, Goals.RandomStroll, &Goals.RandomStroll.trigger/1)

    mind =
      case thorns(data, hit) do
        nil -> mind
        ref -> %{mind | own: Map.update(own(mind), :thorns, [ref], &(&1 ++ [ref]))}
      end

    %{body | mob: %{mob | ai: mind}}
  end

  def hurt(body, _hit), do: body

  defp own(%{own: %{} = own}), do: own
  defp own(_mind), do: %{thorns: []}

  # The living entity that hit it directly, unless it was moving or the
  # damage avoids its thorns.
  defp thorns(%{moving: false}, %{source: source, direct: %{uuid: uuid} = direct}) do
    alias Valimc.Living.DamageSource

    living =
      direct[:player] == true or
        Valimc.Data.EntityTypes.fetch(direct.type).category != :misc

    if living and not DamageSource.is?(source, :avoids_guardian_thorns) and
         DamageSource.type(source) != :thorns,
       do: {if(direct[:player], do: :player, else: :mob), uuid}
  end

  defp thorns(_data, _hit), do: nil

  # ---- the beam

  defmodule Attack do
    @moduledoc """
    `GuardianAttackGoal`, updated every tick: it holds still and looks at
    its target while it sees it (an elder's however close, another's while
    more than three blocks away); ten ticks in it shows the beam, after its
    attack duration it hits and lets go. Stopping clears the beam and the
    target and sends it strolling.
    """
    use Valimc.AI.Goal
    alias Valimc.AI.Goals.RandomStroll
    alias Valimc.AI.Selector

    def new(elder), do: %{elder: elder, time: 0}

    def can_use(state, self) do
      case World.target(self) do
        %{alive: true} -> {true, state, self}
        _ -> {false, state, self}
      end
    end

    def can_continue(state, self) do
      case World.target(self) do
        %{alive: true} = target ->
          {state.elder or World.distance_sq(self, target) > 9.0, state, self}

        _ ->
          {false, state, self}
      end
    end

    def start(state, self) do
      self = Navigation.stop(self)

      self =
        case World.target(self) do
          nil -> self
          target -> look(self, target)
        end

      {%{state | time: -10}, self}
    end

    def stop(state, self) do
      self =
        self
        |> beam(0)
        |> Self.set_target(nil)
        |> Selector.change(:goals, RandomStroll, &RandomStroll.trigger/1)

      {state, self}
    end

    def every_tick?(_state), do: true

    def tick(state, self) do
      case World.target(self) do
        nil ->
          {state, self}

        target ->
          self = self |> Navigation.stop() |> look(target)

          if World.line_of_sight?(self, target) do
            time = state.time + 1
            {%{state | time: time}, attack(self, target, time, state.elder)}
          else
            {state, Self.set_target(self, nil)}
          end
      end
    end

    defp attack(self, target, 0, _elder),
      do: self |> beam(target.id) |> Self.effect({:event, 21})

    defp attack(self, target, time, elder) do
      if time >= if(elder, do: 60, else: 80) do
        magic = 1.0 + if(self.world.difficulty == :hard, do: 2.0, else: 0.0)
        magic = magic + if(elder, do: 2.0, else: 0.0)
        ref = World.ref(target)

        self
        |> Self.effect({:hurt, ref, :indirect_magic, magic, []})
        |> Self.effect({:attack, ref})
        |> Self.set_target(nil)
      else
        self
      end
    end

    defp look(self, target),
      do: Self.look_at(self, {target.x, World.eye_y(target), target.z}, 90.0, 90.0)

    defp beam(self, id), do: %{self | data: %{self.data | beam: id}}
  end
end
