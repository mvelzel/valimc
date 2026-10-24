defmodule Valimc.Entity.Animals.Turtle do
  @moduledoc """
  A turtle (`Turtle`): an amphibious animal with a home beach (`home_pos`,
  where it first spawned or hatched). It wanders the beach, takes to the
  water (and travels far in it), and heads home now and then; on land its
  move control keeps it slow. Bred (with seagrass), the mother gets an egg
  instead of a baby, goes home and lays one to four eggs on sand there
  (`has_egg`, saved; `laying_egg`). A baby grows up dropping a scute
  (`turtle_grow`). Hurt, it runs for water within seven blocks.

  Its travel in water is the guardian's (a tenth of its input, 0.9 drag),
  sinking unless it has a target or swims home from afar. Its steps
  shamble every 0.15 blocks, its swims are half again as loud.
  """
  use Valimc.Entity.Animal, type: "minecraft:turtle"
  alias Valimc.AI.{Goals, Mth, Navigation, RandomPos, Self, World}
  alias Valimc.Data.Float32
  alias Valimc.Entity.Animal

  @type_name "minecraft:turtle"
  @sand MapSet.new(Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:sand"])
  @water Valimc.Data.Blocks.id("water")

  @impl true
  def goals do
    {[
       {0, "TurtlePanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.2, water: 7)},
       {1, "TurtleBreedGoal", Goals.Breed, [:move, :look],
        Goals.Breed.new(1.0, guard: &(not &1.data.has_egg), breed: &breed/2)},
       {1, "TurtleLayEggGoal", __MODULE__.LayEgg, [:move, :jump], __MODULE__.LayEgg.new()},
       {2, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.1, &Animal.food?(@type_name, &1), false)},
       {3, "TurtleGoToWaterGoal", __MODULE__.GoToWater, [:move, :jump],
        __MODULE__.GoToWater.new()},
       {4, "TurtleGoHomeGoal", __MODULE__.GoHome, [], %{stuck: false, close: 0}},
       {7, "TurtleTravelGoal", __MODULE__.Travel, [], %{stuck: false}},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {9, "TurtleRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, interval: 100, guard: &strolls?/1)}
     ], []}
  end

  # A turtle made without a spawn has its home at the origin (`BlockPos.ZERO`).
  @impl true
  def defaults, do: %{has_egg: false, laying_egg: false, home: {0, 0, 0}}

  @impl true
  def fields(data),
    do: [{:turtle_has_egg, data.has_egg, false}, {:turtle_laying_egg, data.laying_egg, false}]

  @impl true
  def offspring(self, _partner), do: {%{home: Self.block(self)}, self}

  @doc "`finalizeSpawn`: its home where it spawned."
  @impl true
  def spawn_part(%Self{data: data} = self, _reason),
    do: %{self | data: %{data | home: Self.block(self)}}

  # What it keeps beyond its saved data: going home, its travel's target,
  # its laying count.
  @own %{going_home: false, travel: nil, lay: 0}

  @doc "Its own state (`Mind.own`)."
  def own(%{own: %{going_home: _} = own}), do: own
  def own(_mind), do: @own

  @doc "Its home."
  def home(%Self{data: %{home: home}}), do: home

  # `BlockPos.closerToCenterThan(position, distance)`.
  defp near?({x, y, z}, self, d) do
    {dx, dy, dz} = {x + 0.5 - self.x, y + 0.5 - self.y, z + 0.5 - self.z}
    dx * dx + dy * dy + dz * dz < d * d
  end

  @doc "Whether its home is within `d` blocks of its centre."
  def near_home?(self, d), do: near?(home(self), self, d)

  defp baby?(%Self{data: data}), do: data.age < 0

  defp strolls?(self),
    do: not Self.in_water?(self) and not own(self.mind).going_home and not self.data.has_egg

  # ---- its controls

  @impl true
  def navigation, do: {:amphibious, []}

  @impl true
  def motion, do: [fluid_pushed: false, step_gap: Float32.round(0.15)]

  @impl true
  def swim_sound, do: "minecraft:entity.turtle.swim"

  @impl true
  def swim_volume, do: 1.5

  @doc "`playStepSound`: a shamble (a baby's own), quiet."
  @impl true
  def step_sound(self) do
    name =
      if baby?(self),
        do: "minecraft:entity.turtle.shamble_baby",
        else: "minecraft:entity.turtle.shamble"

    Valimc.AI.play(self, name, 0.15, 1.0)
  end

  @doc """
  `TurtlePathNavigation.isStableDestination`: water while it travels, else
  anything but air below.
  """
  @impl true
  def stable_destination?(%Self{mind: mind, world: world}, {x, y, z} = pos) do
    if own(mind).travel != nil,
      do: World.block(world, pos) |> water_block?(),
      else: not World.air?(world, {x, y - 1, z})
  end

  defp water_block?(nil), do: false
  defp water_block?(state), do: Valimc.Data.Blocks.block_id(state) == @water

  @doc "`getWalkTargetValue`: water (unless going home) and sand above all."
  @impl true
  def walk_value(%Self{world: world} = self, {x, y, z} = pos) do
    cond do
      not own(self.mind).going_home and World.fluid(world, pos) == :water -> 10.0
      on_sand?(world, {x, y, z}) -> 10.0
      true -> Float32.round(World.light(world, pos) - 0.5)
    end
  end

  @doc "`TurtleEggBlock.onSand`: sand below."
  def on_sand?(world, {x, y, z}), do: sand?(world, {x, y - 1, z})

  @doc "`TurtleEggBlock.isSand`."
  def sand?(world, pos) do
    case World.block(world, pos) do
      nil -> false
      state -> MapSet.member?(@sand, Valimc.Data.Blocks.block_id(state))
    end
  end

  @doc """
  `TurtleMoveControl.tick`: in water a little lift (slower far from home,
  slower still as a baby), on the ground half speed; toward the wanted
  position while it navigates (turning, easing its speed, rising toward its
  target), else still. It travels as a guardian does, sinking unless it has
  a target or is swimming home from afar.
  """
  @impl true
  def move_control(%Self{mob: mob} = self) do
    speed = Self.speed(self)
    f = &Float32.round/1

    {speed, lift} =
      cond do
        Self.in_water?(self) ->
          speed = if near_home?(self, 16.0), do: speed, else: max(f.(speed / 2.0), f.(0.08))
          speed = if baby?(self), do: max(f.(speed / 3.0), f.(0.06)), else: speed
          {speed, [{0.0, 0.005, 0.0}]}

        self.on_ground ->
          {max(f.(speed / 2.0), f.(0.06)), []}

        true ->
          {speed, []}
      end

    {self, speed, push} =
      case mob.motion.control do
        {:move_to, {wx, wy, wz}, modifier} ->
          if Navigation.done?(self.mind.navigation) do
            {self, 0.0, []}
          else
            {xd, yd, zd} = {wx - self.x, wy - self.y, wz - self.z}
            dd = :math.sqrt(xd * xd + yd * yd + zd * zd)

            if dd < f.(1.0e-5) do
              {self, 0.0, []}
            else
              yd = yd / dd
              yaw = Mth.rotlerp(self.yaw, Mth.yaw(xd, zd), 90.0)
              self = Self.mind(%{self | yaw: yaw}, &%{&1 | body_yaw: yaw})

              attribute =
                Valimc.Entity.Mob.value(@type_name, self.mob, "minecraft:movement_speed")

              speed = Mth.lerp(f.(0.125), speed, f.(modifier * attribute))
              {self, speed, [{0.0, speed * yd * 0.1, 0.0}]}
            end
          end

        _ ->
          {self, 0.0, []}
      end

    own = own(self.mind)
    sink = self.mind.target == nil and (not own.going_home or not near_home?(self, 20.0))

    motion = %{
      self.mob.motion
      | set: {speed * 1.0, false},
        impulse: lift ++ push,
        travel: {:guardian, sink}
    }

    %{self | mob: %{self.mob | motion: motion}}
  end

  # ---- sounds

  @doc "On land (not as a baby) it calls; in water it is silent."
  @impl true
  def ambient_sound(self) do
    if not Self.in_water?(self) and self.on_ground and not baby?(self),
      do: "minecraft:entity.turtle.ambient_land"
  end

  @doc "A baby's hurt and death sounds are its own."
  @impl true
  def sound(%{data: %{age: age}}, "hurt_sound") when age < 0,
    do: "minecraft:entity.turtle.hurt_baby"

  def sound(_body, "hurt_sound"), do: "minecraft:entity.turtle.hurt"

  def sound(%{data: %{age: age}}, "death_sound") when age < 0,
    do: "minecraft:entity.turtle.death_baby"

  def sound(_body, "death_sound"), do: "minecraft:entity.turtle.death"
  def sound(_body, _key), do: nil

  # ---- breeding and growing

  @doc """
  `TurtleBreedGoal.breed`: an egg for her instead of a baby; both parents
  rest (age 6000, no love) and an orb is dropped.
  """
  def breed(%Self{} = self, partner) do
    self = %{self | data: %{self.data | has_egg: true, age: 6000, in_love: 0}}
    self = Self.effect(self, {:bred, World.ref(partner)})

    if self.world.mob_drops do
      {n, self} = Self.int(self, 7)
      Self.effect(self, {:orb, n + 1, {self.x, self.y, self.z}})
    else
      self
    end
  end

  @doc "`canFallInLove`: not while carrying an egg."
  def can_fall_in_love?(data), do: not data.has_egg

  @doc """
  `Turtle.aiStep` after its super: laying, the sand under it crumbles every
  five ticks.
  """
  @impl true
  def settle(%Self{} = self) do
    own = own(self.mind)

    if Valimc.Entity.Mob.alive?(self.mob) and self.data.laying_egg and own.lay >= 1 and
         rem(own.lay, 5) == 0 do
      {x, y, z} = Self.block(self)

      if on_sand?(self.world, {x, y, z}),
        do:
          Self.effect(
            self,
            {:level_event, {x, y, z}, 2001, World.block(self.world, {x, y - 1, z})}
          ),
        else: self
    else
      self
    end
  end

  @doc "The actual age transition drops the growth gift, including the first tick after loading."
  @impl Valimc.AI.Kind
  def after_ai(%Self{} = self) do
    was_baby = baby?(self)
    self = Animal.settle(self)

    if was_baby and not baby?(self) and self.world.mob_drops do
      {[a, b], world} = level_doubles(self.world)
      self = %{self | world: world}

      Self.effect(
        self,
        {:gift, "minecraft:gameplay/turtle_grow", {a * 0.2 - 0.1, 0.2, b * 0.2 - 0.1}}
      )
    else
      self
    end
  end

  defp level_doubles(world) do
    {a, random} = Valimc.AI.Random.double(world.random)
    {b, random} = Valimc.AI.Random.double(random)
    {[a, b], %{world | random: random}}
  end

  # ---- its own goals

  defmodule GoToWater do
    @moduledoc """
    `TurtleGoToWaterGoal`: out of water (not going home nor carrying an egg,
    or as a baby), it walks to the nearest water block within 24 around,
    one below its feet; it gives up after 1200 ticks.
    """
    use Valimc.AI.Goal
    alias Valimc.AI.Goals.MoveToBlock
    alias Valimc.Entity.Animals.Turtle

    @water Valimc.Data.Blocks.id("water")

    def new,
      do: MoveToBlock.new(1.0, 24, &water?/3, vertical_start: -1, recalculate: 160)

    defp water?(self, cell, state) do
      ok =
        case World.block(self.world, cell) do
          nil -> false
          s -> Valimc.Data.Blocks.block_id(s) == @water
        end

      {ok, state}
    end

    def every_tick?(_state), do: true

    def can_use(state, self) do
      own = Turtle.own(self.mind)

      cond do
        self.data.age < 0 and not Self.in_water?(self) ->
          MoveToBlock.can_use(state, self)

        not own.going_home and not Self.in_water?(self) and not self.data.has_egg ->
          MoveToBlock.can_use(state, self)

        true ->
          {false, state, self}
      end
    end

    def can_continue(state, self) do
      if not Self.in_water?(self) and state.tries <= 1200 do
        {ok, state} = water?(self, state.cell, state)
        {ok, state, self}
      else
        {false, state, self}
      end
    end

    defdelegate start(state, self), to: MoveToBlock
    defdelegate tick(state, self), to: MoveToBlock
  end

  defmodule LayEgg do
    @moduledoc """
    `TurtleLayEggGoal`: carrying an egg within nine blocks of home, it walks
    to sand with air above within 16 blocks; there, out of water, it starts
    laying and after 200 ticks lays one to four eggs (with the laying
    sound), then falls in love again for 600 ticks.
    """
    use Valimc.AI.Goal
    alias Valimc.AI.Goals.MoveToBlock
    alias Valimc.Entity.Animals.Turtle

    def new, do: MoveToBlock.new(1.0, 16, &sand?/3)

    defp sand?(self, {x, y, z} = cell, state),
      do: {World.air?(self.world, {x, y + 1, z}) and Turtle.sand?(self.world, cell), state}

    def every_tick?(_state), do: true

    def can_use(state, self) do
      if self.data.has_egg and Turtle.near_home?(self, 9.0),
        do: MoveToBlock.can_use(state, self),
        else: {false, state, self}
    end

    def can_continue(state, self) do
      {ok, state, self} = MoveToBlock.can_continue(state, self)
      {ok and self.data.has_egg and Turtle.near_home?(self, 9.0), state, self}
    end

    defdelegate start(state, self), to: MoveToBlock

    def tick(state, self) do
      {state, self} = MoveToBlock.tick(state, self)
      own = Turtle.own(self.mind)

      if not Self.in_water?(self) and state.reached do
        self =
          cond do
            own.lay < 1 ->
              lay(self, true)

            own.lay > adjusted(state, 200) ->
              self |> lay_eggs(state.cell) |> lay(false)

            true ->
              self
          end

        {state, if(self.data.laying_egg, do: count(self), else: self)}
      else
        {state, self}
      end
    end

    defp lay(self, on) do
      self = %{self | data: %{self.data | laying_egg: on}}
      Self.mind(self, &%{&1 | own: %{Turtle.own(&1) | lay: if(on, do: 1, else: 0)}})
    end

    defp count(self),
      do: Self.mind(self, &%{&1 | own: %{Turtle.own(&1) | lay: Turtle.own(&1).lay + 1}})

    # The eggs on the sand's top (one to four), the laying sound (a pitch
    # from the level's random) and love for 600 ticks.
    defp lay_eggs(self, {x, y, z}) do
      {f, random} = Valimc.AI.Random.float(self.world.random)
      self = %{self | world: %{self.world | random: random}}
      pitch = Float32.round(Float32.round(0.9) + Float32.round(f * Float32.round(0.2)))
      {n, self} = Self.int(self, 4)

      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
      sound = Valimc.AI.Facts.sound_id("minecraft:entity.turtle.lay_egg")

      self
      |> Self.effect({:sound_block, sound, "blocks", Float32.round(0.3), pitch, seed})
      |> Self.effect({:lay_eggs, {x, y + 1, z}, n + 1})
      |> Map.update!(:data, &%{&1 | has_egg: false, in_love: 600})
    end
  end

  defmodule GoHome do
    @moduledoc """
    `TurtleGoHomeGoal`: carrying an egg, or now and then when more than 64
    blocks from home, it heads home in steps toward it; it stops within seven
    blocks, stuck, or after trying 600 ticks close by.
    """
    use Valimc.AI.Goal
    alias Valimc.Entity.Animals.Turtle

    @tenth Float32.round(:math.pi() / 10.0)
    @quarter Float32.round(:math.pi() / 2.0)

    def can_use(state, self) do
      cond do
        self.data.age < 0 ->
          {false, state, self}

        self.data.has_egg ->
          {true, state, self}

        true ->
          {n, self} = Self.int(self, Mth.reduced(700))
          {n == 0 and not Turtle.near_home?(self, 64.0), state, self}
      end
    end

    def start(state, self) do
      self = Self.mind(self, &%{&1 | own: %{Turtle.own(&1) | going_home: true}})
      {%{state | stuck: false, close: 0}, self}
    end

    def stop(state, self),
      do: {state, Self.mind(self, &%{&1 | own: %{Turtle.own(&1) | going_home: false}})}

    def can_continue(state, self) do
      ok =
        not Turtle.near_home?(self, 7.0) and not state.stuck and
          state.close <= adjusted(state, 600)

      {ok, state, self}
    end

    def tick(state, self) do
      close = Turtle.near_home?(self, 16.0)
      state = if close, do: %{state | close: state.close + 1}, else: state

      if Navigation.done?(self.mind.navigation) do
        {hx, hy, hz} = Turtle.home(self)
        home = {hx + 0.5, hy * 1.0, hz + 0.5}

        {next, self} =
          case RandomPos.default_towards(self, 16, 3, home, @tenth) do
            {nil, self} -> RandomPos.default_towards(self, 8, 7, home, @quarter)
            found -> found
          end

        {next, self} =
          if next != nil and not close and not water?(self, next),
            do: RandomPos.default_towards(self, 16, 5, home, @quarter),
            else: {next, self}

        case next do
          nil ->
            {%{state | stuck: true}, self}

          pos ->
            {_, self} = Navigation.move_to(self, pos, 1.0)
            {state, self}
        end
      else
        {state, self}
      end
    end

    @water Valimc.Data.Blocks.id("water")

    defp water?(self, {x, y, z}) do
      case World.block(self.world, {floor(x), floor(y), floor(z)}) do
        nil -> false
        s -> Valimc.Data.Blocks.block_id(s) == @water
      end
    end
  end

  defmodule Travel do
    @moduledoc """
    `TurtleTravelGoal`: in water (not going home nor carrying an egg) it sets
    out for a spot up to 512 blocks away (no higher than the sea) and swims
    toward it in steps until stuck, in love or going home.
    """
    use Valimc.AI.Goal
    alias Valimc.Entity.Animals.Turtle

    @tenth Float32.round(:math.pi() / 10.0)
    @quarter Float32.round(:math.pi() / 2.0)

    def can_use(state, self) do
      own = Turtle.own(self.mind)
      {not own.going_home and not self.data.has_egg and Self.in_water?(self), state, self}
    end

    def start(state, self) do
      {xt, self} = Self.int(self, 1025)
      {yt, self} = Self.int(self, 9)
      {zt, self} = Self.int(self, 1025)
      {xt, yt, zt} = {xt - 512, yt - 4, zt - 512}
      yt = if yt + self.y > self.world.sea_level - 1, do: 0, else: yt
      target = {floor(xt + self.x), floor(yt + self.y), floor(zt + self.z)}
      self = Self.mind(self, &%{&1 | own: %{Turtle.own(&1) | travel: target}})
      {%{state | stuck: false}, self}
    end

    def stop(state, self),
      do: {state, Self.mind(self, &%{&1 | own: %{Turtle.own(&1) | travel: nil}})}

    # `hasChunksAt` 34 blocks around the next spot: every chunk there
    # readable.
    defp loaded?(self, {x, _, z}) do
      {xc, zc} = {floor(x), floor(z)}
      y = floor(self.y)

      Enum.all?(
        for(
          cx <- Integer.floor_div(xc - 34, 16)..Integer.floor_div(xc + 34, 16),
          cz <- Integer.floor_div(zc - 34, 16)..Integer.floor_div(zc + 34, 16),
          do: {cx, cz}
        ),
        &World.chunk?(self.world, &1, y)
      )
    end

    def can_continue(state, self) do
      own = Turtle.own(self.mind)

      ok =
        not Navigation.done?(self.mind.navigation) and not state.stuck and not own.going_home and
          self.data.in_love <= 0 and not self.data.has_egg

      {ok, state, self}
    end

    def tick(state, self) do
      case Turtle.own(self.mind).travel do
        nil ->
          {%{state | stuck: true}, self}

        {tx, ty, tz} ->
          if Navigation.done?(self.mind.navigation) do
            target = {tx + 0.5, ty * 1.0, tz + 0.5}

            {next, self} =
              case RandomPos.default_towards(self, 16, 3, target, @tenth) do
                {nil, self} -> RandomPos.default_towards(self, 8, 7, target, @quarter)
                found -> found
              end

            next = if next != nil and loaded?(self, next), do: next

            case next do
              nil ->
                {%{state | stuck: true}, self}

              pos ->
                {_, self} = Navigation.move_to(self, pos, 1.0)
                {state, self}
            end
          else
            {state, self}
          end
      end
    end
  end
end
