defmodule Valimc.Entity.Animals.Cat do
  @moduledoc """
  A cat (`Cat`, VMC-044a3), a stray: it creeps toward a player holding cod or
  salmon (`CatTemptGoal`, now and then not scared of that player), creeps
  and then sprints away from other survival players (`CatAvoidEntityGoal`),
  hunts rabbits (`NonTameRandomTargetGoal`, `LeapAtTargetGoal`,
  `OcelotAttackGoal`), strolls and looks about. Its variant (`CatVariant`)
  is the spawn's (a swamp hut's are black, and some are black at full moon),
  its sounds its sound variant's (a stray's meow). It crouches while its
  move control creeps and sprints at a sprint's speed
  (`customServerAiStep`).

  Its goals for a tamed cat (sitting when ordered, following its owner,
  relaxing on its owner's bed, lying on and sitting on blocks) are
  registered as vanilla's are and never start for a stray. Taming
  (feeding a stray fish), collars and a tamed cat's morning gifts are
  VMC-043's taming.
  """
  use Valimc.Entity.Animal, type: "minecraft:cat"
  alias Valimc.AI.{Goals, Self}
  alias Valimc.Entity.Animal

  @type_name "minecraft:cat"
  @variants "minecraft:cat_variant"
  @sounds "minecraft:cat_sound_variant"
  @rabbit "minecraft:rabbit"
  # `LivingEntity.SPEED_MODIFIER_SPRINTING`: 0.3F, `ADD_MULTIPLIED_TOTAL`.
  @sprinting {"minecraft:sprinting", 0.30000001192092896, 2}
  @speed "minecraft:movement_speed"

  @impl true
  def goals do
    never = &Goals.Idle.new/1

    {[
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "TamableAnimalPanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.5)},
       {2, "SitWhenOrderedToGoal", Goals.Idle, [:move, :jump], never.("SitWhenOrderedToGoal")},
       {3, "CatRelaxOnOwnerGoal", Goals.Idle, [], never.("CatRelaxOnOwnerGoal")},
       {4, "CatTemptGoal", __MODULE__.Tempt, [:move, :look], __MODULE__.Tempt.new()},
       {5, "CatLieOnBlockGoal", Goals.Idle, [:move, :jump], never.("CatLieOnBlockGoal")},
       {6, "FollowOwnerGoal", Goals.Idle, [:move, :look], never.("FollowOwnerGoal")},
       {7, "CatSitOnBlockGoal", Goals.Idle, [:move, :jump], never.("CatSitOnBlockGoal")},
       {8, "LeapAtTargetGoal", Goals.LeapAtTarget, [:move, :jump], Goals.LeapAtTarget.new(0.3)},
       {9, "OcelotAttackGoal", Goals.OcelotAttack, [:move, :look], Goals.OcelotAttack.new()},
       {10, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(0.8)},
       {11, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(0.8, water_avoiding: true, probability: 1.0000001e-5)},
       {12, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(10.0)},
       # `reassessTameGoals`: a stray avoids players (added after the rest).
       {4, "CatAvoidEntityGoal", Goals.AvoidEntity, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :player), 16.0, 0.8, 1.33)}
     ],
     [
       {1, "NonTameRandomTargetGoal", __MODULE__.Hunt, [:target], __MODULE__.Hunt.new([@rabbit])},
       # `Turtle.BABY_ON_LAND_SELECTOR`: turtles are VMC-043e's.
       {1, "NonTameRandomTargetGoal", __MODULE__.Hunt, [:target],
        __MODULE__.Hunt.new(["minecraft:turtle"])}
     ]}
  end

  @impl true
  def defaults,
    do: %{
      variant: "minecraft:black",
      sound_variant: "minecraft:classic",
      collar: 14,
      lying: false,
      relax: false,
      tame: false,
      sitting: false,
      crouching: false,
      sprinting: false
    }

  @impl true
  def fields(data) do
    flags = if(data.sitting, do: 1, else: 0) + if(data.tame, do: 4, else: 0)

    [
      {:tamable_flags, flags, 0},
      {:tamable_owner, nil, nil},
      {:cat_variant, Animal.variant_id(@variants, data.variant),
       Animal.variant_id(@variants, "minecraft:black")},
      {:cat_lying, data.lying, false},
      {:cat_relax_state_one, data.relax, false},
      {:cat_collar_color, data.collar, 14},
      {:cat_sound_variant, Animal.variant_id(@sounds, data.sound_variant),
       Animal.variant_id(@sounds, "minecraft:classic")}
    ]
  end

  @impl true
  def properties(data), do: [{"minecraft:cat/variant", data.variant}]

  @doc "A child's variant: either parent's (a stray's child has no owner or collar)."
  @impl true
  def offspring(%Self{} = self, partner) do
    {mine, self} = Self.boolean(self)
    {%{variant: if(mine, do: self.data.variant, else: partner.data.variant)}, self}
  end

  @doc """
  `Cat.finalizeSpawn`: `Mob`'s part first, then the variant to spawn
  (`selectVariantToSpawn`) and a random sound variant, from the level's
  random.
  """
  @impl Valimc.AI.Kind
  def finalize(%Self{} = self, reason) do
    self = Valimc.AI.Spawn.mob(self, reason)
    {variant, self} = Animal.pick_variant(self, @variants)
    {sound, self} = Animal.pick_random(self, @sounds)
    %{self | data: %{self.data | variant: variant, sound_variant: sound}}
  end

  @doc """
  `Cat.customServerAiStep` (in place of `Animal`'s): crouching while its
  move control creeps (speed 0.6), sprinting at 1.33, standing otherwise.
  """
  @impl true
  def server_ai_step(%Self{mob: mob} = self) do
    {crouching, sprinting} =
      case mob.motion.control do
        {:move_to, _, 0.6} -> {true, false}
        {:move_to, _, 1.33} -> {false, true}
        _ -> {false, false}
      end

    self
    |> sprint(sprinting)
    |> then(&%{&1 | data: %{&1.data | crouching: crouching}})
  end

  # `LivingEntity.setSprinting`: its flag and the sprint speed modifier.
  defp sprint(%Self{mob: mob} = self, on) do
    {id, _, _} = @sprinting
    entry = Map.get(mob.attributes, @speed, %{base: nil, modifiers: []})
    modifiers = Enum.reject(entry.modifiers, &(elem(&1, 0) == id))
    modifiers = if on, do: modifiers ++ [@sprinting], else: modifiers
    attributes = Map.put(mob.attributes, @speed, %{entry | modifiers: modifiers})
    %{self | mob: %{mob | attributes: attributes}, data: %{self.data | sprinting: on}}
  end

  @doc """
  `Entity.baseTick`'s sprint particles (`canSpawnSprintParticle`): a
  sprinting cat out of water and not crouching draws for one each tick.
  """
  @impl Valimc.AI.Kind
  def tick_start(%Self{data: data} = self) do
    if data.sprinting and not data.crouching and not Self.in_water?(self),
      do: Self.sprint_particle(self),
      else: self
  end

  @doc """
  `Cat.tick` after its super: a stray being tempted begs for food every 100
  ticks.
  """
  @impl Valimc.AI.Kind
  def after_tick(%Self{} = self) do
    if rem(self.mind.tick, 100) == 0 and not self.data.tame and tempted?(self),
      do: sound(self, "beg_for_food", 1.0, 1.0),
      else: self
  end

  defp tempted?(%Self{mind: mind}) do
    {goals, _} = goals()

    Enum.zip(Tuple.to_list(mind.goals), goals)
    |> Enum.any?(fn {goal, {_, name, _, _, _}} ->
      name == "CatTemptGoal" and goal.running
    end)
  end

  defp sound(self, which, volume, pitch) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    id = Animal.sound_id(sound_name(self.data, which))
    source = Valimc.Protocol.CombatPackets.mob_sounds(@type_name)["sound_source"]
    Self.effect(self, {:sound, id, source, volume, pitch, seed})
  end

  # Sound `which` of its sound variant's set, a kitten's own.
  defp sound_name(data, which) do
    set = Animal.sound_variant(@sounds, data.sound_variant)
    if(data.age < 0, do: set["baby"], else: set["adult"])[which]
  end

  @doc "`getAmbientSound`: a stray's meow (a tamed cat's purrs are taming's)."
  @impl true
  def ambient_sound(%Self{data: data}), do: Animal.sound_id(sound_name(data, "stray_ambient"))

  # Its hurt and death sounds are its sound variant's.
  @impl true
  def sound(body, key) do
    which = if key == "hurt_sound", do: "hurt", else: "death"
    Animal.sound_id(sound_name(body.data, which))
  end

  @doc "`Cat.mobInteract` of a stray with its food: taming is VMC-043's, so it takes nothing."
  @impl true
  def interact(%{data: data}, %{item: %{item_id: id}}) do
    if not data.tame and Animal.food?(@type_name, id), do: :consume, else: :pass
  end

  def interact(_body, _use), do: :pass
end

defmodule Valimc.Entity.Animals.Cat.Tempt do
  @moduledoc """
  `Cat.CatTemptGoal`: `TemptGoal` (0.6, scared by a moving player) for a
  stray. While tempted it now and then picks the player as one it is not
  scared of (one update in `adjustedTickDelay(600)`) and forgets it (one in
  `adjustedTickDelay(500)`).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.Tempt
  alias Valimc.Entity.Animal

  def new,
    do: %{tempt: Tempt.new(0.6, &Animal.food?("minecraft:cat", &1), true), selected: nil}

  def can_use(state, self) do
    if self.data.tame do
      {false, state, self}
    else
      {ok, tempt, self} = Tempt.can_use(state.tempt, self)
      {ok, %{state | tempt: tempt}, self}
    end
  end

  # `canScare`: not by the player it picked.
  def can_continue(state, self) do
    tempt = state.tempt
    scare = state.selected == nil or state.selected != tempt.player
    {ok, tempt, self} = Tempt.can_continue(%{tempt | scare: scare}, self)
    {ok, %{state | tempt: %{tempt | scare: true}}, self}
  end

  def start(state, self) do
    {tempt, self} = Tempt.start(state.tempt, self)
    {%{state | tempt: tempt}, self}
  end

  def stop(state, self) do
    {tempt, self} = Tempt.stop(state.tempt, self)
    {%{state | tempt: tempt}, self}
  end

  def tick(state, self) do
    {tempt, self} = Tempt.tick(state.tempt, self)
    state = %{state | tempt: tempt}

    {picked, self} =
      if state.selected == nil do
        {n, self} = Self.int(self, adjusted(state, 600))
        {n == 0, self}
      else
        {false, self}
      end

    if picked do
      {%{state | selected: tempt.player}, self}
    else
      {m, self} = Self.int(self, adjusted(state, 500))
      {if(m == 0, do: %{state | selected: nil}, else: state), self}
    end
  end
end

defmodule Valimc.Entity.Animals.Cat.Hunt do
  @moduledoc """
  `NonTameRandomTargetGoal` (one update in ten, not needing sight): a stray
  targets the nearest mob of its types; it keeps it while the targeting
  conditions hold (alive, attackable, within the follow range).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.{NearestAttackableTarget, Target}

  def new(types), do: NearestAttackableTarget.new(:mob, types, false)

  def can_use(state, self) do
    if self.data.tame,
      do: {false, state, self},
      else: NearestAttackableTarget.can_use(state, self)
  end

  def can_continue(state, self) do
    follow = Target.follow(self)
    conditions = World.conditions(true, range: follow)

    case World.entity(self.world, state.found) do
      nil ->
        {false, state, self}

      target ->
        {ok, self} = World.test(self, target, conditions)
        {ok, state, self}
    end
  end

  def start(state, self), do: NearestAttackableTarget.start(state, self)
  def stop(state, self), do: NearestAttackableTarget.stop(state, self)
end
