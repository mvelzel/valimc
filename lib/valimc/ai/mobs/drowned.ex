defmodule Valimc.AI.Mobs.Drowned do
  @moduledoc """
  Drowned (VMC-043b2), as vanilla's `Drowned`, a zombie
  (`Valimc.AI.Mobs.Zombie` keeps its data, babies, hits and attributes):

  - **Goals**: the zombie's turtle eggs and looks, then its own: by day out
    of water it heads for water ten blocks around; a trident thrower throws
    at its target (`RangedAttackGoal`), else melee, either only at night or
    at a target in water; at night in shallow water it goes ashore
    (`MoveToBlockGoal`) and from deeper water swims up; it wanders.
    Targets: whoever hurt it (not a drowned; zombified piglins join in),
    players it may attack, villagers, iron golems, axolotls and baby
    turtles on land.
  - **Swimming**: underwater and wanting to swim (searching for land, or
    after a target in water) it swims (`DrownedMoveControl`: turning
    toward where it goes, easing its speed, pushed along and up; the
    kernel's fish travel, no gravity, not pushed by currents); out of it
    it walks, a little heavier in the air (`-0.008`).
  - **Spawning**: no armour; a trident (10 in 16) or fishing rod one time
    in ten, a nautilus shell in the off hand three times in a hundred, and
    the zombie nautilus a natural trident thrower may ride (its draws; the
    nautilus and riding are VMC-046's).
  - Its sounds are its own, in water their watery kinds.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Mth, Navigation, Self, Spawn, World}
  alias Valimc.AI.Mobs.Zombie
  alias Valimc.Data.Float32
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @drowned "minecraft:drowned"
  @turtle_eggs Enum.to_list(Valimc.Data.Blocks.states("turtle_egg"))
  @villagers ["minecraft:villager", "minecraft:wandering_trader"]
  @trident ItemTypes.id("trident")
  @shell ItemTypes.id("nautilus_shell")
  @spears MapSet.new(Valimc.Protocol.Data.tags()["minecraft:item"]["minecraft:spears"])
  @preferred MapSet.new(
               Valimc.Protocol.Data.tags()["minecraft:item"][
                 "minecraft:drowned_preferred_weapons"
               ]
             )
  @frequent "minecraft:more_frequent_drowned_spawns"

  @impl true
  def types, do: [@drowned]

  @doc "`AmphibiousPathNavigation`."
  @impl true
  def navigation, do: {:amphibious, []}

  ## Goals

  @impl true
  def goals(_type) do
    {[
       {4, "ZombieAttackTurtleEggGoal", Goals.RemoveBlock, [:move, :jump],
        Goals.RemoveBlock.new(@turtle_eggs)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {1, "DrownedGoToWaterGoal", __MODULE__.GoToWater, [:move], %{wanted: nil}},
       {2, "DrownedTridentAttackGoal", __MODULE__.Trident, [:move, :look],
        __MODULE__.Trident.new()},
       {2, "DrownedAttackGoal", __MODULE__.Attack, [:move, :look], __MODULE__.Attack.new()},
       {5, "DrownedGoToBeachGoal", Goals.MoveToBlock, [:move, :jump],
        Goals.MoveToBlock.new(1.0, 8, &beach?/3, vertical: 2, guard: &beach_time?/1)},
       {6, "DrownedSwimUpGoal", __MODULE__.SwimUp, [], %{stuck: false}},
       {7, "RandomStrollGoal", Goals.RandomStroll, [:move], Goals.RandomStroll.new(1.0)}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(
          ignore: [@drowned],
          alert: true,
          alert_types: ["minecraft:zombified_piglin"]
        )},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true,
          interval: 10,
          selector: fn target, self -> ok_target?(self, target) end
        )},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, @villagers, false)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:iron_golem"], true)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:axolotl"], true)},
       # `Turtle.BABY_ON_LAND_SELECTOR`: turtles are VMC-043e's.
       {5, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:turtle"], true, interval: 10)}
     ]}
  end

  @doc "`okTarget`: at night any, by day only one in water."
  def ok_target?(%Self{world: world}, target),
    do: target != nil and (not world.bright or World.in_water?(world, target))

  @doc "`wantsToSwim`: searching for land, or after a target in water."
  def wants_to_swim?(%Self{} = self) do
    self.data.searching or
      case World.target(self) do
        nil -> false
        target -> World.in_water?(self.world, target)
      end
  end

  # `DrownedGoToBeachGoal`: at night in water near the surface, a block it
  # can stand on with two empty blocks above.
  defp beach_time?(%Self{} = self),
    do: not self.world.bright and Self.in_water?(self) and self.y >= self.world.sea_level - 3

  defp beach?(%Self{world: world} = self, {x, y, z} = cell, state) do
    standable =
      World.air?(world, {x, y + 1, z}) and World.air?(world, {x, y + 2, z}) and
        stand_on?(self, cell)

    {standable, state}
  end

  # `entityCanStandOn`: a full top face to stand on.
  defp stand_on?(%Self{world: world}, cell) do
    case World.block(world, cell) do
      nil -> false
      state -> Valimc.Data.BlockFacts.flag?(state, :collision_up)
    end
  end

  ## Data

  @impl true
  def data(_type), do: Map.merge(Zombie.data(@drowned), %{searching: false, swimming: false})

  @impl true
  def values(body), do: Zombie.values(body)

  @impl true
  def dimensions(body), do: Zombie.dimensions(body)

  @impl true
  def voice(type, data), do: Zombie.voice(type, data)

  def baby?(body), do: Zombie.baby?(body)
  def set_baby(self, baby), do: Zombie.set_baby(self, baby)

  @impl true
  def hit(self, target), do: Zombie.hit(self, target)

  @impl true
  def ambient_sound(%Self{facts: facts} = self),
    do:
      if(Self.in_water?(self),
        do: "minecraft:entity.drowned.ambient_water",
        else: facts.ambient_sound
      )

  @impl true
  def sound(%{mob: mob}, "hurt_sound"),
    do: watery(mob, "minecraft:entity.drowned.hurt")

  def sound(%{mob: mob}, "death_sound"),
    do: watery(mob, "minecraft:entity.drowned.death")

  def sound(_body, _key), do: nil

  @impl true
  def swim_sound, do: "minecraft:entity.drowned.swim"

  defp watery(mob, name), do: if(mob.motion.water > 0.0, do: name <> "_water", else: name)

  ## Loot

  @doc "`wantsToPickUp`: no spears; a zombie's otherwise."
  @impl true
  def wants?(self, item), do: not MapSet.member?(@spears, item) and Zombie.wants?(self, item)

  @doc "`canReplaceCurrentItem`: a nautilus shell stays."
  @impl true
  def can_hold?(%Self{mob: mob}, _item),
    do: not match?(%{item_id: @shell}, mob.equipment[:offhand])

  @impl true
  def preferred_weapons(_type), do: @preferred

  ## Spawning

  @doc """
  `finalizeSpawn`: a zombie's with its own equipment, then a nautilus shell
  now and then, then the zombie nautilus a natural adult trident thrower
  may ride outside the warm oceans' frequent spawns.
  """
  @impl true
  def finalize(self, reason) do
    self = Zombie.zombie(self, reason, populate: &equipment/1)

    {f, self} = Spawn.level_float(self)

    self =
      if self.mob.equipment[:offhand] == nil and f < Float32.round(0.03) do
        self = Spawn.equip(self, :offhand, ItemStack.new("nautilus_shell"))
        %{self | mob: Valimc.Entity.Mob.put_drop_chance(self.mob, :offhand, 2.0)}
      else
        self
      end

    nautilus(self, reason)
  end

  # `populateDefaultEquipmentSlots`: a trident or a fishing rod, no armour.
  defp equipment(self) do
    {f, self} = Spawn.level_float(self)

    if f > 0.9 do
      {n, self} = Spawn.level_int(self, 16)
      item = if n < 10, do: "trident", else: "fishing_rod"
      Spawn.equip(self, :mainhand, ItemStack.new(item))
    else
      self
    end
  end

  # The zombie nautilus's spawn: its variant for the biome, its attack
  # cooldown memory, then a mob's draws.
  defp nautilus(self, reason) do
    if reason in [:natural, :structure] and
         match?(%{item_id: @trident}, self.mob.equipment[:mainhand]) do
      {f, self} = Spawn.level_float(self)
      biome = World.biome(self.world, Self.block(self))

      if f < Float32.round(0.5) and not self.data.baby and
           not Valimc.Entity.Animal.biome_in?(biome, @frequent) do
        {_, self} = Valimc.Entity.Animal.pick_variant(self, "minecraft:zombie_nautilus_variant")
        {_, self} = Spawn.level_int(self, 1201)
        {_, self} = Spawn.level_double(self)
        {_, self} = Spawn.level_double(self)
        {_, self} = Spawn.level_float(self)
        # The nautilus it rides: zombie nautiluses and riding are VMC-046's,
        # so the owner makes none yet.
        Self.effect(self, {:spawn, "minecraft:zombie_nautilus", %{jockey: true, yaw: self.yaw}})
      else
        self
      end
    else
      self
    end
  end

  ## Swimming

  @doc """
  `updateSwimming` and the travel it picks (`travelInWater`): underwater
  and wanting to swim it swims, as a fish travels, unpushed by currents.
  """
  @impl true
  def before_ai(%Self{} = self) do
    swimming = self.mob.motion.eye_water and wants_to_swim?(self)
    %{self | data: %{self.data | swimming: swimming}}
  end

  @doc "`DrownedMoveControl.tick`."
  @impl true
  def move_control(%Self{mob: mob} = self) do
    if wants_to_swim?(self) and Self.in_water?(self) do
      target = World.target(self)

      up =
        if (target != nil and target.y > self.y) or self.data.searching, do: 0.002, else: 0.0

      self = travel(self)

      # Its lift is its own step before the push.
      lift = {0.0, up, 0.0}

      case mob.motion.control do
        {:move_to, {wx, wy, wz}, modifier} ->
          if Navigation.done?(self.mind.navigation),
            do: set(self, 0.0, [lift]),
            else: swim(self, {wx, wy, wz}, modifier, lift)

        _ ->
          set(self, 0.0, [lift])
      end
    else
      down = if self.on_ground, do: 0.0, else: -0.008
      motion = %{mob.motion | impulse: [{0.0, down, 0.0}]}
      travel(%{self | mob: %{mob | motion: motion}})
    end
  end

  defp swim(self, {wx, wy, wz}, modifier, lift) do
    {xd, yd, zd} = {wx - self.x, wy - self.y, wz - self.z}
    dd = :math.sqrt(xd * xd + yd * yd + zd * zd)
    yd = yd / dd
    yaw = Mth.rotlerp(self.yaw, Mth.yaw(xd, zd), 90.0)
    self = Self.mind(%{self | yaw: yaw}, &%{&1 | body_yaw: yaw})
    attribute = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:movement_speed")
    target = Float32.round(modifier * attribute)
    speed = Mth.lerp(Float32.round(0.125), Self.speed(self), target)
    set(self, speed, [lift, {speed * xd * 0.005, speed * yd * 0.1, speed * zd * 0.005}])
  end

  defp set(%Self{mob: mob} = self, speed, impulse) do
    motion = %{mob.motion | set: {speed * 1.0, false}, impulse: impulse}
    %{self | mob: %{mob | motion: motion}}
  end

  # Underwater and wanting to swim as it travels, it travels as a fish
  # does (no sinking).
  defp travel(%Self{mob: mob} = self) do
    travel = if mob.motion.eye_water and wants_to_swim?(self), do: {:fish, false}, else: nil
    %{self | mob: %{mob | motion: %{mob.motion | travel: travel}}}
  end

  @doc "Whether the drowned holds a trident."
  def trident?(%Self{mob: mob}), do: match?(%{item_id: @trident}, mob.equipment[:mainhand])

  @doc """
  `performRangedAttack`: a trident (its own, or a new one) thrown from its
  eyes at the target's lower third (`{:throw_trident, ...}`), and its sound.
  """
  def throw(%Self{} = self, target, _power) do
    stack = self.mob.equipment[:mainhand] || ItemStack.new("trident")
    from_y = Self.eye_y(self) - 0.10000000149011612
    xd = target.x - self.x
    yd = target.y + target.height * 0.3333333333333333 - from_y
    zd = target.z - self.z
    dist = :math.sqrt(xd * xd + zd * zd)
    {f, self} = Self.float(self)

    pitch =
      Float32.round(
        1.0 / Float32.round(Float32.round(f * Float32.round(0.4)) + Float32.round(0.8))
      )

    self
    |> Self.effect(
      {:throw_trident,
       %{
         stack: stack,
         from: {self.x, from_y, self.z},
         direction: {xd, yd + dist * Float32.round(0.2), zd},
         velocity: 1.6,
         uncertainty: uncertainty(self.world.difficulty)
       }}
    )
    |> Self.sound("minecraft:entity.drowned.shoot", 1.0, pitch)
  end

  # `RangedAttackMob.rangedAttackUncertainty`: `14 - difficulty * 4`.
  defp uncertainty(difficulty) do
    level = Enum.find_index([:peaceful, :easy, :normal, :hard], &(&1 == difficulty)) || 2
    (14 - level * 4) * 1.0
  end
end

defmodule Valimc.AI.Mobs.Drowned.GoToWater do
  @moduledoc """
  `DrownedGoToWaterGoal`: by day out of water it tries ten spots within ten
  blocks around and two above to six below for water and heads for the
  first.
  """
  use Valimc.AI.Goal

  @water Valimc.Data.Blocks.id("water")

  def can_use(state, self) do
    cond do
      not self.world.bright -> {false, state, self}
      Self.in_water?(self) -> {false, state, self}
      true -> find(state, self, 10)
    end
  end

  defp find(state, self, 0), do: {false, state, self}

  defp find(state, self, n) do
    {bx, by, bz} = Self.block(self)
    {a, self} = Self.int(self, 20)
    {b, self} = Self.int(self, 8)
    {c, self} = Self.int(self, 20)
    cell = {bx + a - 10, by + 2 - b, bz + c - 10}

    case World.block(self.world, cell) do
      state_id when is_integer(state_id) ->
        if Valimc.Data.Blocks.block_id(state_id) == @water do
          {x, y, z} = cell
          {true, %{state | wanted: {x + 0.5, y * 1.0, z + 0.5}}, self}
        else
          find(state, self, n - 1)
        end

      _ ->
        find(state, self, n - 1)
    end
  end

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.wanted, 1.0)
    {state, self}
  end
end

defmodule Valimc.AI.Mobs.Drowned.Attack do
  @moduledoc "`DrownedAttackGoal`: a zombie's attack, only at targets it may go after (`okTarget`)."
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.MeleeAttack
  alias Valimc.AI.Mobs.Drowned

  def new, do: MeleeAttack.new(1.0, false, raise_arms: true)

  def can_use(state, self) do
    case MeleeAttack.can_use(state, self) do
      {true, state, self} -> {Drowned.ok_target?(self, World.target(self)), state, self}
      other -> other
    end
  end

  def can_continue(state, self) do
    case MeleeAttack.can_continue(state, self) do
      {true, state, self} -> {Drowned.ok_target?(self, World.target(self)), state, self}
      other -> other
    end
  end

  def start(state, self), do: MeleeAttack.start(state, self)
  def stop(state, self), do: MeleeAttack.stop(state, self)
  def tick(state, self), do: MeleeAttack.tick(state, self)
  def every_tick?(state), do: MeleeAttack.every_tick?(state)
end

defmodule Valimc.AI.Mobs.Drowned.Trident do
  @moduledoc """
  `DrownedTridentAttackGoal`: `RangedAttackGoal` (speed 1, every 40 ticks
  within ten blocks) while it holds a trident, aggressive and using it
  while it runs.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.RangedAttack
  alias Valimc.AI.Mobs.Drowned

  def new, do: RangedAttack.new(1.0, 40, 40, 10.0, &Drowned.throw/3)

  def can_use(state, self) do
    case RangedAttack.can_use(state, self) do
      {true, state, self} -> {Drowned.trident?(self), state, self}
      other -> other
    end
  end

  def can_continue(state, self), do: RangedAttack.can_continue(state, self)

  def start(state, self) do
    {state, self} = RangedAttack.start(state, self)
    {state, self |> Self.set_aggressive(true) |> Self.start_using(:main_hand)}
  end

  def stop(state, self) do
    {state, self} = RangedAttack.stop(state, self)
    {state, self |> Self.stop_using() |> Self.set_aggressive(false)}
  end

  def tick(state, self), do: RangedAttack.tick(state, self)
  def every_tick?(state), do: RangedAttack.every_tick?(state)
end

defmodule Valimc.AI.Mobs.Drowned.SwimUp do
  alias Valimc.Data.Float32

  @moduledoc """
  `DrownedSwimUpGoal`: at night in water two blocks below sea level it
  searches for land, swimming up toward a spot below the surface whenever
  it has nowhere to go or is close to it; with none to be found it is
  stuck and stops.
  """
  use Valimc.AI.Goal

  defp usable?(self),
    do: not self.world.bright and Self.in_water?(self) and self.y < self.world.sea_level - 2

  def can_use(state, self), do: {usable?(self), state, self}
  def can_continue(state, self), do: {usable?(self) and not state.stuck, state, self}

  def start(state, self),
    do: {%{state | stuck: false}, %{self | data: %{self.data | searching: true}}}

  def stop(state, self), do: {state, %{self | data: %{self.data | searching: false}}}

  def tick(state, self) do
    sea = self.world.sea_level

    if self.y < sea - 1 and (Navigation.done?(self.mind.navigation) or close?(self)) do
      radians = Float32.round(:math.pi() / 2)

      case Valimc.AI.RandomPos.default_towards(self, 4, 8, {self.x, sea - 1.0, self.z}, radians) do
        {nil, self} ->
          {%{state | stuck: true}, self}

        {{x, y, z}, self} ->
          {_, self} = Navigation.move_to(self, {x, y, z}, 1.0)

          {state, self}
      end
    else
      {state, self}
    end
  end

  # `closeToNextPos`: within two blocks of its path's end.
  defp close?(self) do
    case self.mind.navigation.path do
      %{target: {x, y, z}} ->
        {dx, dy, dz} = {x - self.x, y - self.y, z - self.z}
        dx * dx + dy * dy + dz * dz < 4.0

      _ ->
        false
    end
  end
end
