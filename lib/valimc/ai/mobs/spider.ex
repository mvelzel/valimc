defmodule Valimc.AI.Mobs.Spider do
  @moduledoc """
  Spiders and cave spiders (VMC-043b4), as vanilla's `Spider` and
  `CaveSpider`:

  - **Goals**: floating, fleeing armadillos, leaping at a target two to four
    blocks away, chasing it even unseen (giving up now and then in the
    light), wandering and looking around; the player and iron golems as
    targets only in the dark, whoever hurt it any time.
  - **Climbing**: a spider that bumped into a wall climbs it
    (`setClimbing(horizontalCollision)`, its `onClimbable`), and its paths
    lead to the target's block even where no path does
    (`WallClimberNavigation`).
  - **Spawning**: a skeleton jockey one time in a hundred (riding is
    VMC-046's) and, on hard, now and then an endless speed, strength,
    regeneration or invisibility. A cave spider draws nothing.
  - **Bites**: a cave spider's poisons for 7 seconds (15 on hard).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Self, Spawn, World}
  alias Valimc.Data.Float32

  @spider "minecraft:spider"
  @cave "minecraft:cave_spider"

  @impl true
  def types, do: [@spider, @cave]

  @impl true
  def navigation, do: {:ground, climber: true}

  @impl true
  def goals(_type) do
    light = &dark?/1

    {[
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       # Armadillos are VMC-043c's: none is scared yet.
       {2, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
        Goals.AvoidEntity.new(
          &(&1.kind == :mob and &1.type == "minecraft:armadillo"),
          6.0,
          1.0,
          1.2
        )},
       {3, "LeapAtTargetGoal", Goals.LeapAtTarget, [:move, :jump], Goals.LeapAtTarget.new(0.4)},
       {4, "SpiderAttackGoal", __MODULE__.Attack, [:move, :look], __MODULE__.Attack.new()},
       {5, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(0.8, water_avoiding: true)},
       {6, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {6, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target], Goals.HurtByTarget.new()},
       {2, "SpiderTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true, when: light)},
       {3, "SpiderTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:iron_golem"], true, when: light)}
     ]}
  end

  # `SpiderTargetGoal.canUse`: only below half brightness where its eyes are.
  defp dark?(%Self{} = self), do: brightness(self) < 0.5

  @doc "`getLightLevelDependentMagicValue` at the spider's eyes."
  def brightness(%Self{} = self),
    do: World.light(self.world, {floor(self.x), floor(Self.eye_y(self)), floor(self.z)})

  @impl true
  def data(_type), do: %{climbing: false}

  @impl true
  def values(%{data: data}), do: [{:spider_flags, if(data.climbing, do: 1, else: 0), 0}]

  @doc "`Spider.onClimbable`: it climbs what it bumped into (the kernel's wall climbing)."
  @impl true
  def climbs?(%{data: data}), do: data.climbing

  @doc "`Spider.tick` after the move: `setClimbing(horizontalCollision)`."
  @impl true
  def after_move(%{data: data} = body, _position, ticked),
    do: {%{body | data: %{data | climbing: ticked.mob.horizontal_collision}}, []}

  ## Spawning

  @effects ["speed", "speed", "strength", "regeneration", "invisibility"]

  @impl true
  def finalize(%Self{type: @cave} = self, _reason), do: self

  def finalize(self, reason) do
    self = Spawn.mob(self, reason)
    {n, self} = Spawn.level_int(self, 100)
    self = if n == 0, do: Spawn.companion(self, "minecraft:skeleton", :jockey), else: self

    if self.world.difficulty == :hard do
      {f, self} = Spawn.level_float(self)

      if f < Float32.round(Float32.round(0.1) * Spawn.special(self)) do
        {i, self} = Spawn.level_int(self, 5)
        effect = Valimc.Data.EffectTypes.id(Enum.at(@effects, i))
        %{self | mob: Valimc.Entity.Mob.add_effect(self.mob, effect, {-1, 0, false, true, true})}
      else
        self
      end
    else
      self
    end
  end

  ## Bites

  @poison Valimc.Data.EffectTypes.id("poison")

  @doc "`CaveSpider.doHurtTarget`: a poisoning bite (none on easy)."
  @impl true
  def hit(%Self{type: @cave, world: world} = self, target) do
    seconds =
      case world.difficulty do
        :normal -> 7
        :hard -> 15
        _ -> 0
      end

    if seconds > 0,
      do:
        Self.effect(
          self,
          {:attack_extra, World.ref(target),
           %{effect: {@poison, {seconds * 20, 0, false, true, true}}}}
        ),
      else: self
  end

  def hit(self, _target), do: self
end

defmodule Valimc.AI.Mobs.Spider.Attack do
  @moduledoc """
  `SpiderAttackGoal`: melee that follows an unseen target, unless it rides
  something; in light of half brightness or more it gives up one time in a
  hundred, dropping its target.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.MeleeAttack
  alias Valimc.AI.Mobs.Spider

  def new, do: MeleeAttack.new(1.0, true)

  def can_use(state, self), do: MeleeAttack.can_use(state, self)

  def can_continue(state, self) do
    if Spider.brightness(self) >= 0.5 do
      {n, self} = Self.int(self, 100)

      if n == 0,
        do: {false, state, Self.set_target(self, nil)},
        else: MeleeAttack.can_continue(state, self)
    else
      MeleeAttack.can_continue(state, self)
    end
  end

  defdelegate start(state, self), to: MeleeAttack
  defdelegate stop(state, self), to: MeleeAttack
  defdelegate tick(state, self), to: MeleeAttack
  defdelegate every_tick?(state), to: MeleeAttack
end
