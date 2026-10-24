defmodule Valimc.AI.Mobs.Dolphin do
  @moduledoc """
  `Dolphin`: a smart swimmer that breathes air. It swims to random spots
  in water by its smooth swimming move control (turning ten degrees a tick,
  pitching up to 85 toward its target, its input split between forward and
  up), looks with the smooth swimming look control, travels in water at its
  own speed with 0.9 drag (sinking slowly without a target), and leaps out
  of the water now and then. It holds its breath for 4800 ticks and swims
  up for air below 140; out of water it dries out over 2400 ticks (rain
  keeps it moist), flopping about. Hurt by a player it bites back (and
  alerts the others); it shies from guardians, plays with items in the
  water (taking one in its mouth and tossing it) and eats fish from a
  player's hand (`GotFish`).

  Its moistness and whether it got fish are its data (saved); a fish it ate
  sends it to treasure, which needs a structure search the AI cannot run
  inside its tick yet (it gives up at once, as vanilla does when nothing is
  near).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Mth, Navigation, Self, SmoothSwimming, World}
  alias Valimc.Data.Float32
  alias Valimc.Data.Mth, as: Table
  alias Valimc.Protocol.ItemStack

  @type_name "minecraft:dolphin"
  @max_air 4800
  @moist 2400
  @flop Float32.round(0.2)
  @radians Float32.round(:math.pi() / 180.0)
  @controls %{max_x: 85.0, max_y: 10.0, in_water: 0.02, out: 0.1, gravity: true}
  @fishes MapSet.new(Valimc.Protocol.Data.tags()["minecraft:item"]["minecraft:fishes"])

  @guardians ["minecraft:guardian", "minecraft:elder_guardian"]

  @impl true
  def types, do: [@type_name]

  @impl true
  def goals(_type) do
    {[
       {0, "BreathAirGoal", Goals.BreathAir, [:move, :look], Goals.BreathAir.new()},
       {0, "TryFindLiquidGoal", Goals.TryFindLiquid, [], Goals.TryFindLiquid.new()},
       {1, "DolphinSwimToTreasureGoal", __MODULE__.Treasure, [:move, :look], %{}},
       {2, "DolphinSwimWithPlayerGoal", __MODULE__.SwimWithPlayer, [:move, :look],
        __MODULE__.SwimWithPlayer.new(4.0)},
       {4, "RandomSwimmingGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, interval: 10, swim: true)},
       {4, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {5, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {5, "DolphinJumpGoal", __MODULE__.Jump, [:move, :jump], __MODULE__.Jump.new(10)},
       {6, "MeleeAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(Float32.round(1.2), true)},
       {7, "MoveToItemGoal", __MODULE__.MoveToItem, [:move], %{cooldown: 0}},
       {8, "PlayWithItemsGoal", __MODULE__.PlayWithItems, [], %{}},
       {8, "FollowPlayerRiddenEntityGoal", Goals.FollowRidden, [], Goals.FollowRidden.new()},
       {8, "FollowPlayerRiddenEntityGoal", Goals.FollowRidden, [], Goals.FollowRidden.new()},
       {9, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
        Goals.AvoidEntity.new(&guardian?/1, 8.0, 1.0, 1.0)}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, ignore: @guardians)}
     ]}
  end

  defp guardian?(%{type: type}), do: type in @guardians
  defp guardian?(_entity), do: false

  @doc "`WaterBoundPathNavigation` that may breach the surface."
  @impl true
  def navigation, do: {:water, breaching: true}

  @impl true
  # Its travel when its AI does not choose one (dead, `NoAI`): no target.
  def motion, do: [fluid_pushed: false, travel: {:dolphin, true}]

  @impl true
  def swim_sound, do: "minecraft:entity.dolphin.swim"

  @impl true
  def data(_type),
    do:
      Map.merge(Valimc.Entity.Animal.ageable_data(), %{
        got_fish: false,
        moistness: @moist,
        treasure: nil
      })

  @impl true
  def values(%{data: data}),
    do: [
      {:ageable_baby, data.age < 0, false},
      {:age_locked, data.age_locked, false},
      {:dolphin_got_fish, data.got_fish, false},
      {:dolphin_moistness, data.moistness, @moist}
    ]

  @impl true
  def dimensions(%{type: type, data: %{age: age}}) when age < 0,
    do: Valimc.Entity.Animal.water_ageable(type).baby

  def dimensions(_), do: nil

  @impl true
  def after_ai(self), do: Valimc.Entity.Animal.settle_ageable(self)

  @impl true
  def voice(_type, data), do: Valimc.Entity.Animal.voice(data)

  @impl true
  def can_attack?(%Self{data: data}, _target), do: data.age >= 0

  @doc "`getMaxAirSupply`."
  @impl true
  def max_air, do: @max_air

  @doc "`finalizeSpawn`: full air, level."
  @impl true
  def finalize(%Self{} = self, reason), do: Valimc.AI.Spawn.mob(spawn_part(self), reason)

  @doc "Dolphin's part before AgeableMob.finalizeSpawn."
  def spawn_part(%Self{mob: mob} = self) do
    mob = %{mob | living: %{mob.living | air_supply: @max_air}}
    %{self | mob: mob, pitch: 0.0}
  end

  @doc """
  `LivingEntity.baseTick`'s air with a dolphin's supply: its eyes in water
  use it up (drowning at -20), out of water it is full at once.
  """
  @impl true
  def breath(%Self{mob: mob} = self) do
    air = mob.living.air_supply

    cond do
      Self.submerged?(self) and not Valimc.Living.Air.breathes?(mob.living.effects) ->
        if air - 1 <= -20, do: {0, 2.0}, else: {air - 1, 0.0}

      true ->
        {@max_air, 0.0}
    end
  end

  @doc "In water it calls one way, out of it another."
  @impl true
  def ambient_sound(self) do
    if Self.in_water?(self),
      do: "minecraft:entity.dolphin.ambient_water",
      else: "minecraft:entity.dolphin.ambient"
  end

  # ---- its controls

  @doc """
  `SmoothSwimmingMoveControl(85, 10, 0.02, 0.1, true)`
  (`Valimc.AI.SmoothSwimming`); it travels as a dolphin, sinking without a
  target.
  """
  @impl true
  def move_control(self) do
    self = SmoothSwimming.move(self, @controls)
    travel = {:dolphin, self.mind.target == nil}
    %{self | mob: %{self.mob | motion: %{self.mob.motion | travel: travel}}}
  end

  @doc "`SmoothSwimmingLookControl(10)` (`Valimc.AI.SmoothSwimming`)."
  @impl true
  def look_control(self), do: SmoothSwimming.look(self, 10.0)

  # ---- its tick

  @doc "Whether it was in water as its tick began (its tick reads it after the move)."
  @impl true
  def before_ai(self), do: Self.mind(self, &%{&1 | own: Self.in_water?(self)})

  @doc """
  `Dolphin.tick` after its super: moist in water or rain, else drying (hurt
  each tick once dry) and flopping on the ground.
  """
  @impl true
  def after_tick(%Self{mob: %{no_ai: true} = mob} = self),
    do: %{self | mob: %{mob | living: %{mob.living | air_supply: @max_air}}}

  def after_tick(%Self{data: data} = self) do
    if self.mind.own == true or raining?(self) do
      %{self | data: %{data | moistness: @moist}}
    else
      self = %{self | data: %{data | moistness: data.moistness - 1}}
      self = if self.data.moistness <= 0, do: dry_out(self), else: self

      if self.on_ground do
        {a, self} = Self.float(self)
        {b, self} = Self.float(self)
        side = &Float32.round(Float32.round(Float32.round(&1 * 2.0) - 1.0) * @flop)
        {vx, vy, vz} = self.velocity
        {f, self} = Self.float(self)

        %{
          self
          | velocity: {vx + side.(a), vy + 0.5, vz + side.(b)},
            yaw: Float32.round(f * 360.0),
            on_ground: false
        }
      else
        self
      end
    end
  end

  defp raining?(%Self{world: %{rain: nil}}), do: false

  defp raining?(%Self{world: %{rain: rain}} = self),
    do: rain.({self.x, self.y, self.z}, self.y + self.height)

  # `hurt(dryOut(), 1)`, through the one hurt path.
  defp dry_out(%Self{mob: mob} = self) do
    {mob, events, _} =
      Valimc.Entity.Combat.hurt_mob(self.type, %{mob | ai: self.mind}, :dry_out, 1.0, self.data)

    self = %{self | mob: %{mob | ai: nil}, mind: mob.ai}
    Enum.reduce(events, self, &Self.effect(&2, &1))
  end

  # ---- items

  @doc "`Dolphin.pickUpItem`: an item into its empty mouth, whole."
  @impl true
  def pick_up(%Self{mob: mob} = self, item) do
    if mob.equipment[:mainhand] == nil do
      stack = %ItemStack{item_id: item.item, count: item.count, components: item.components}
      chances = Map.put(mob.drop_chances, :mainhand, 2.0)
      mob = %{mob | equipment: Map.put(mob.equipment, :mainhand, stack), drop_chances: chances}

      %{self | mob: mob}
      |> Self.effect({:pickup, World.ref(item), item.count})
      |> Valimc.AI.Pickup.remove(item, item.count)
    else
      self
    end
  end

  @doc """
  `ItemGoal.dropItem`: what is in its mouth, tossed ahead from below its
  eyes (40 ticks before anyone may take it).
  """
  def toss(%Self{mob: mob} = self) do
    case mob.equipment[:mainhand] do
      nil ->
        {false, self}

      stack ->
        {dir, self} = Self.float(self)
        dir = Float32.round(dir * Float32.round(:math.pi() * 2.0))
        {p, self} = Self.float(self)
        pow = Float32.round(Float32.round(0.02) * p)
        yaw = Float32.round(self.yaw * @radians)
        pitch = Float32.round(self.pitch * @radians)
        f = &Float32.round/1
        speed = f.(0.3)

        velocity =
          {f.(f.(f.(speed * -Table.sin(yaw)) * Table.cos(pitch)) + f.(Table.cos(dir) * pow)),
           f.(f.(speed * Table.sin(pitch)) * f.(1.5)),
           f.(f.(f.(speed * Table.cos(yaw)) * Table.cos(pitch)) + f.(Table.sin(dir) * pow))}

        at = {self.x, Self.eye_y(self) - Float32.round(0.3), self.z}
        mob = %{mob | equipment: Map.delete(mob.equipment, :mainhand)}
        {true, Self.effect(%{self | mob: mob}, {:throw, stack, at, velocity, 40})}
    end
  end

  @doc "The items it may play with: free, in the water, within eight blocks."
  def items(%Self{world: world} = self) do
    box = World.inflate(Self.box(self), 8.0, 8.0, 8.0)

    for item <- world.items,
        item.count > 0 and item.pickup_delay == 0,
        World.intersects?(World.box(item), box),
        World.fluid(world, Mth.block({item.x, item.y, item.z})) == :water,
        do: item
  end

  # ---- interaction

  @doc """
  `Dolphin.mobInteract`: a fish from a player's hand is eaten (it then has
  fish, `GotFish`).
  """
  @impl true
  def mob_interact(body, %{item: %ItemStack{item_id: id}}) do
    if MapSet.member?(@fishes, id) do
      events = [
        {:sound, Valimc.AI.Facts.sound_id("minecraft:entity.dolphin.eat"), "neutral", 1.0, 1.0,
         seed()}
      ]

      body =
        if Valimc.Entity.Animal.can_age_up?(body.data),
          do: Valimc.Entity.Animal.feed_baby(body),
          else: %{body | data: %{body.data | got_fish: true}}

      {:ok, body,
       Valimc.Entity.Animals.Interaction.outcome(hand: {:use, 1}, swing: true, events: events)}
    else
      :pass
    end
  end

  def mob_interact(_body, _request), do: :pass

  defp seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end

  @doc "`playAttackSound` after a bite."
  @impl true
  def hit(self, _target), do: Valimc.AI.play(self, "minecraft:entity.dolphin.attack")

  # ---- its own goals

  defmodule Treasure do
    @moduledoc """
    `DolphinSwimToTreasureGoal`: a dolphin that ate fish (with air to spare)
    looks for treasure. The structure search runs outside the AI (`Worldgen.Locate`),
    which a tick cannot wait for, so it finds none and, as vanilla does then,
    gives up and forgets the fish.
    """
    use Valimc.AI.Goal

    def can_use(state, self),
      do: {self.data.got_fish and self.mob.living.air_supply >= 100, state, self}

    def can_continue(state, self), do: {false, state, self}

    def interruptable?(_state), do: false

    def start(state, self), do: {state, Navigation.stop(self)}

    def stop(state, self), do: {state, %{self | data: %{self.data | got_fish: false}}}
  end

  defmodule SwimWithPlayer do
    @moduledoc """
    `DolphinSwimWithPlayerGoal`: it swims along with the nearest player
    swimming within ten blocks (seen or not) and gives it Dolphin's Grace for
    five seconds now and then.
    """
    use Valimc.AI.Goal

    def new(speed), do: %{speed: speed, player: nil}

    def can_use(state, self) do
      conditions = World.conditions(false, range: 10.0, sight: false)

      case World.nearest_player(self, conditions, self.x, self.y, self.z) do
        {nil, self} ->
          {false, %{state | player: nil}, self}

        {player, self} ->
          ok = Map.get(player, :swimming, false) and self.mind.target != World.ref(player)
          {ok, %{state | player: World.ref(player)}, self}
      end
    end

    def can_continue(state, self) do
      case World.entity(self.world, state.player) do
        %{} = p ->
          {Map.get(p, :swimming, false) and World.distance_sq(self, p) < 256.0, state, self}

        nil ->
          {false, state, self}
      end
    end

    def start(state, self), do: {state, grace(self, state.player)}

    def stop(state, self), do: {%{state | player: nil}, Navigation.stop(self)}

    def tick(state, self) do
      case World.entity(self.world, state.player) do
        nil ->
          {state, self}

        player ->
          self = Self.look_at(self, {player.x, World.eye_y(player), player.z}, 21.0, 1.0)

          self =
            if World.distance_sq(self, player) < 6.25 do
              Navigation.stop(self)
            else
              {_, self} = Navigation.move_to_entity(self, player, state.speed)
              self
            end

          # The player's level random (`player.level().getRandom()`).
          if Map.get(player, :swimming, false) do
            {n, self} = Valimc.AI.Spawn.level_int(self, 6)
            if n == 0, do: {state, grace(self, state.player)}, else: {state, self}
          else
            {state, self}
          end
      end
    end

    @grace Valimc.Data.EffectTypes.id("dolphins_grace")

    defp grace(self, ref),
      do: Self.effect(self, {:effect, ref, [{:add, @grace, [{100, 0, false, true, true}]}]})
  end

  defmodule Jump do
    @moduledoc """
    `DolphinJumpGoal`: now and then (one chance in half its interval), with
    clear water ahead along its heading and air above it, it leaps: motion
    0.6 ahead and 0.7 up; while in the air it pitches along its flight and
    splashes back in with its jump sound.
    """
    use Valimc.AI.Goal

    @steps [0, 1, 4, 5, 6, 7]
    @blocks_jump MapSet.new(
                   Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:blocks_dolphin_jump"] ||
                     []
                 )

    def new(interval), do: %{interval: Mth.reduced(interval), breached: false}

    def can_use(state, self) do
      {n, self} = Self.int(self, state.interval)

      if n != 0 do
        {false, state, self}
      else
        {sx, sz} = direction(self)
        {x, y, z} = Self.block(self)

        clear =
          Enum.all?(@steps, fn i ->
            p = {x + sx * i, y, z + sz * i}

            World.fluid(self.world, p) == :water and not blocks?(self.world, p) and
              World.air?(self.world, {x + sx * i, y + 1, z + sz * i}) and
              World.air?(self.world, {x + sx * i, y + 2, z + sz * i})
          end)

        {clear, state, self}
      end
    end

    defp blocks?(world, pos) do
      case World.block(world, pos) do
        nil -> true
        state -> MapSet.member?(@blocks_jump, Valimc.Data.Blocks.block_id(state))
      end
    end

    # `getMotionDirection`: the horizontal direction its yaw faces.
    defp direction(%Self{yaw: yaw}) do
      case Integer.mod(floor(yaw / 90.0 + 0.5), 4) do
        0 -> {0, 1}
        1 -> {-1, 0}
        2 -> {0, -1}
        3 -> {1, 0}
      end
    end

    def can_continue(state, self) do
      {_, vy, _} = self.velocity

      ok =
        (not (vy * vy < Float32.round(0.03)) or self.pitch == 0.0 or not (abs(self.pitch) < 10.0) or
           not Self.in_water?(self)) and not self.on_ground

      {ok, state, self}
    end

    def interruptable?(_state), do: false

    def start(state, self) do
      {sx, sz} = direction(self)
      {vx, vy, vz} = self.velocity
      self = %{self | velocity: {vx + sx * 0.6, vy + 0.7, vz + sz * 0.6}}
      {%{state | breached: false}, Navigation.stop(self)}
    end

    def stop(state, self), do: {state, %{self | pitch: 0.0}}

    def tick(state, self) do
      breached = state.breached or World.fluid(self.world, Self.block(self)) == :water

      self =
        if breached and not state.breached,
          do: Valimc.AI.play(self, "minecraft:entity.dolphin.jump"),
          else: self

      {vx, vy, vz} = self.velocity

      self =
        cond do
          vy * vy < Float32.round(0.03) and self.pitch != 0.0 ->
            %{self | pitch: Mth.rot_lerp(Float32.round(0.2), self.pitch, 0.0)}

          :math.sqrt(vx * vx + vy * vy + vz * vz) > Float32.round(1.0e-5) ->
            h = :math.sqrt(vx * vx + vz * vz)

            %{
              self
              | pitch: Float32.round(:math.atan2(-vy, h) * 180.0 / Float32.round(:math.pi()))
            }

          true ->
            self
        end

      {%{state | breached: breached}, self}
    end
  end

  defmodule MoveToItem do
    @moduledoc """
    `MoveToItemGoal`: it swims to the first item it may play with (with its
    play sound), and when done tosses what it holds, waiting a while.
    """
    use Valimc.AI.Goal
    alias Valimc.AI.Mobs.Dolphin

    def can_use(state, self) do
      if state.cooldown > self.mind.tick,
        do: {false, state, self},
        else: {Dolphin.items(self) != [], state, self}
    end

    def can_continue(state, self), do: can_use(state, self)

    def start(state, self) do
      self =
        case Dolphin.items(self) do
          [item | _] ->
            {_, self} = Navigation.move_to_entity(self, item, Float32.round(1.2))
            Valimc.AI.play(self, "minecraft:entity.dolphin.play")

          [] ->
            self
        end

      {%{state | cooldown: 0}, self}
    end

    def stop(state, self) do
      case Dolphin.toss(self) do
        {true, self} ->
          {n, self} = Self.int(self, 100)
          {%{state | cooldown: self.mind.tick + n}, self}

        {false, self} ->
          {state, self}
      end
    end

    def tick(state, self) do
      case Dolphin.items(self) do
        [item | _] ->
          {_, self} = Navigation.move_to_entity(self, item, Float32.round(1.2))
          {state, self}

        [] ->
          {state, self}
      end
    end
  end

  defmodule PlayWithItems do
    @moduledoc "`PlayWithItemsGoal`: while it holds something, it tosses it."
    use Valimc.AI.Goal
    alias Valimc.AI.Mobs.Dolphin

    def can_use(state, self), do: {self.mob.equipment[:mainhand] != nil, state, self}

    def stop(state, self), do: {state, elem(Dolphin.toss(self), 1)}

    def tick(state, self), do: {state, elem(Dolphin.toss(self), 1)}
  end
end
