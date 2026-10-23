defmodule Valimc.Entity.Animals.Rabbit do
  @moduledoc """
  A rabbit (`Rabbit`): its goals (fleeing players, wolves and monsters,
  raiding grown carrots), its type (`RabbitType`: brown, white, black,
  white splotched, gold, salt; the killer bunny is VMC-043b's monsters'),
  the ticks before it raids again (`MoreCarrotTicks`) and its hops
  (`hop/1`, `RabbitMoveControl`, `RabbitJumpControl` and its
  `customServerAiStep`).

  A child takes a type of its biome one time in twenty, else either
  parent's; the biome's type draws on the level's random first
  (`getRandomRabbitVariant`).
  """
  use Valimc.Entity.Animal, type: "minecraft:rabbit"
  alias Valimc.AI.{Goals, Mth, Navigation, Random, Self, World}
  alias Valimc.Data.Float32
  alias Valimc.Entity.Animal

  @types %{brown: 0, white: 1, black: 2, white_splotched: 3, gold: 4, salt: 5, evil: 99}

  @doc "The rabbit types by name (`Rabbit.Variant`)."
  def variants, do: @types

  @impl true
  def goals do
    {[
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "ClimbOnTopOfPowderSnowGoal", Goals.ClimbPowderSnow, [:jump], %{}},
       {1, "RabbitPanicGoal", __MODULE__.Panic, [:move], Goals.Panic.new(2.2)},
       {2, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(0.8)},
       {3, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.0, &Animal.food?("minecraft:rabbit", &1), false)},
       {4, "RabbitAvoidEntityGoal", __MODULE__.Avoid, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :player), 8.0, 2.2, 2.2)},
       {4, "RabbitAvoidEntityGoal", __MODULE__.Avoid, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :mob and &1.type == "minecraft:wolf"), 10.0, 2.2, 2.2)},
       {4, "RabbitAvoidEntityGoal", __MODULE__.Avoid, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :mob and Animal.monster?(&1.type)), 4.0, 2.2, 2.2)},
       {5, "RaidGardenGoal", __MODULE__.RaidGarden, [:move, :jump], __MODULE__.RaidGarden.new()},
       {6, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(0.6, water_avoiding: true)},
       {11, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(10.0)}
     ], []}
  end

  @impl true
  def defaults, do: %{type: 0, more_carrots: 0}

  @impl true
  def fields(data), do: [{:rabbit_type, data.type, 0}]

  @impl true
  def properties(data) do
    name = Enum.find_value(@types, :brown, fn {name, id} -> if id == data.type, do: name end)
    [{"minecraft:rabbit/variant", Atom.to_string(name)}]
  end

  @impl true
  def offspring(%Self{} = self, partner) do
    {biome_type, random} =
      biome_type(self.world.random, World.biome(self.world, Self.block(self)))

    self = %{self | world: %{self.world | random: random}}
    {n, self} = Self.int(self, 20)

    if n != 0 do
      {theirs, self} = Self.boolean(self)
      {%{type: if(theirs, do: partner.data.type, else: self.data.type)}, self}
    else
      {%{type: biome_type}, self}
    end
  end

  @doc """
  `finalizeSpawn`'s type: its biome's (`getRandomRabbitVariant`), from the
  level's random. (A pack's kits share it and are all babies; ValiMC's
  spawns finalize alone.)
  """
  @impl true
  def spawn_part(%Self{} = self, _reason) do
    {type, random} = biome_type(self.world.random, Animal.biome(self))
    %{self | world: %{self.world | random: random}, data: %{self.data | type: type}}
  end

  @doc """
  `getRandomRabbitVariant`: the type of biome `biome`, drawn from the
  level's `random`: `{type, random}`.
  """
  def biome_type(random, biome) do
    {n, random} = Random.int(random, 100)

    type =
      cond do
        Animal.biome_in?(biome, "minecraft:spawns_white_rabbits") ->
          if n < 80, do: @types.white, else: @types.white_splotched

        Animal.biome_in?(biome, "minecraft:spawns_gold_rabbits") ->
          @types.gold

        n < 50 ->
          @types.brown

        n < 90 ->
          @types.salt

        true ->
          @types.black
      end

    {type, random}
  end

  @doc """
  `Rabbit.setSpeedModifier`: its navigation's speed, and its move control
  wanting where it wanted, at that speed.
  """
  def set_speed_modifier(%Self{mob: mob} = self, speed) do
    self = Navigation.speed(self, speed)
    wanted = mob.motion.hop.wanted || {self.x, self.y, self.z}
    Self.move_to(self, wanted, speed)
  end

  @jump_sound "minecraft:entity.rabbit.jump"
  @hop %{jump_ticks: 0, jump_duration: 0, was_on_ground: false, jump_delay: 0, can_jump: false}

  defp hop_state(%Self{mind: mind}), do: Map.merge(@hop, mind.own || %{})
  defp put_hop(self, state), do: Self.mind(self, &%{&1 | own: state})

  defp put_motion_hop(%Self{mob: mob} = self, fun),
    do: %{self | mob: %{mob | motion: %{mob.motion | hop: fun.(mob.motion.hop)}}}

  @doc """
  `Rabbit.customServerAiStep`: its landing delay and carrot hunger count
  down; landing ends its hop and waits 10 ticks (3 when fleeing); on the
  ground, with somewhere to go and no delay, it faces its path's next node
  (or where it wants to go) and starts a hop.
  """
  @impl true
  def server_ai_step(%Self{} = self) do
    state = hop_state(self)
    state = if state.jump_delay > 0, do: %{state | jump_delay: state.jump_delay - 1}, else: state

    self =
      if self.data.more_carrots > 0 do
        {n, self} = Self.int(self, 3)
        %{self | data: %{self.data | more_carrots: max(0, self.data.more_carrots - n)}}
      else
        self
      end

    {self, state} =
      if self.on_ground do
        {self, state} =
          if state.was_on_ground do
            {self, state}
          else
            delay = if self.mob.motion.hop.speed < 2.2, do: 10, else: 3

            {put_motion_hop(self, &%{&1 | jumping: false}),
             %{state | jump_delay: delay, can_jump: false}}
          end

        cond do
          not self.mind.jump and match?({:move_to, _, _}, self.mob.motion.control) and
              state.jump_delay == 0 ->
            {:move_to, wanted, _} = self.mob.motion.control
            {x, _, z} = Navigation.next_entity_position(self) || wanted

            yaw =
              Float32.round(
                Float32.round(Mth.atan2(z - self.z, x - self.x) * 57.2957763671875) - 90.0
              )

            start_jumping(%{self | yaw: yaw}, state)

          self.mind.jump and not state.can_jump ->
            {self, %{state | can_jump: true}}

          true ->
            {self, state}
        end
      else
        {self, state}
      end

    put_hop(self, %{state | was_on_ground: self.on_ground})
    |> path_up()
  end

  # `startJumping`: jumping for 15 ticks, the jump sound (`setJumping(true)`).
  defp start_jumping(self, state) do
    self = put_motion_hop(self, &%{&1 | jumping: true})
    {a, self} = Self.float(self)
    {b, self} = Self.float(self)

    pitch =
      Float32.round(
        Float32.round(Float32.round(Float32.round(a - b) * Float32.round(0.2)) + 1.0) *
          Float32.round(0.8)
      )

    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    self =
      Self.effect(
        self,
        {:sound, Animal.sound_id(@jump_sound), source(), self.facts.volume, pitch, seed}
      )

    {self, %{state | jump_duration: 15, jump_ticks: 0}}
  end

  defp source, do: Valimc.Protocol.CombatPackets.mob_sounds("minecraft:rabbit")["sound_source"]

  # What `getJumpPower` reads of its path: the next node above it.
  defp path_up(self) do
    up =
      case Navigation.next_entity_position(self) do
        {_, y, _} -> y > self.y + 0.5
        nil -> false
      end

    put_motion_hop(self, &Map.put(&1, :path_up, up))
  end

  @doc """
  `Rabbit.aiStep` after the move: a hop its jump control started this tick
  (its sound, `startJumping`), the navigation speed its move control set,
  the hop event, then its hop's ticks run out.
  """
  @impl true
  def settle(%Self{mob: %{motion: %{hop: hop}}} = self) do
    state = hop_state(self)

    {self, state} =
      if Map.get(hop, :started, false), do: start_jumping(self, state), else: {self, state}

    self =
      case Map.get(hop, :nav_speed) do
        nil -> self
        speed -> Navigation.speed(self, speed)
      end

    self = if Map.get(hop, :jumped, false), do: Self.effect(self, {:event, 1}), else: self
    self = put_motion_hop(self, &Map.drop(&1, [:started, :jumped, :nav_speed, :path_up]))

    cond do
      state.jump_ticks != state.jump_duration ->
        put_hop(self, %{state | jump_ticks: state.jump_ticks + 1})

      state.jump_duration != 0 ->
        self
        |> put_motion_hop(&%{&1 | jumping: false})
        |> put_hop(%{state | jump_ticks: 0, jump_duration: 0})

      true ->
        put_hop(self, state)
    end
  end

  defmodule Panic do
    @moduledoc "`RabbitPanicGoal`: a panic that sets the rabbit's speed each update."
    use Valimc.AI.Goal
    alias Valimc.AI.Goals
    alias Valimc.Entity.Animals.Rabbit

    defdelegate can_use(state, self), to: Goals.Panic
    defdelegate can_continue(state, self), to: Goals.Panic
    defdelegate start(state, self), to: Goals.Panic
    defdelegate stop(state, self), to: Goals.Panic

    def tick(state, self), do: {state, Rabbit.set_speed_modifier(self, state.speed)}
  end

  defmodule Avoid do
    @moduledoc "`RabbitAvoidEntityGoal`: avoiding, unless it is the killer bunny."
    use Valimc.AI.Goal
    alias Valimc.AI.Goals

    def can_use(state, %{data: %{type: 99}} = self), do: {false, state, self}
    def can_use(state, self), do: Goals.AvoidEntity.can_use(state, self)
    defdelegate can_continue(state, self), to: Goals.AvoidEntity
    defdelegate start(state, self), to: Goals.AvoidEntity
    defdelegate stop(state, self), to: Goals.AvoidEntity
    defdelegate tick(state, self), to: Goals.AvoidEntity
  end

  defmodule RaidGarden do
    @moduledoc """
    `RaidGardenGoal`: while mobs may grief, a rabbit that wants food walks
    to a grown carrot on farmland within sixteen blocks and eats a stage of
    it (the youngest goes, `{:raid_carrot, cell}`); it wants food again 40
    ticks later.
    """
    use Valimc.AI.Goal
    alias Valimc.AI.Goals.MoveToBlock
    alias Valimc.Data.Blocks

    @supports MapSet.new(
                Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:supports_crops"]
              )
    @carrots Blocks.id("carrots")

    def new do
      MoveToBlock.new(0.7, 16, &valid/3, own: %{wants: false, can_raid: false})
    end

    def every_tick?(_state), do: true

    def can_use(%{next: next} = state, self) when next > 0, do: MoveToBlock.can_use(state, self)

    def can_use(state, self) do
      if self.world.mob_griefing do
        own = %{state.own | can_raid: false, wants: self.data.more_carrots <= 0}
        MoveToBlock.can_use(%{state | own: own}, self)
      else
        {false, state, self}
      end
    end

    def can_continue(%{own: %{can_raid: false}} = state, self), do: {false, state, self}
    def can_continue(state, self), do: MoveToBlock.can_continue(state, self)

    defdelegate start(state, self), to: MoveToBlock

    def tick(state, self) do
      {state, self} = MoveToBlock.tick(state, self)
      {x, y, z} = state.cell
      self = Self.look_at(self, {x + 0.5, y + 1.0, z + 0.5}, 10.0, self.facts.max_head_x_rot)

      if state.reached do
        crop = {x, y + 1, z}

        self =
          if state.own.can_raid and carrot?(World.block(self.world, crop)) do
            self
            |> Self.effect({:raid_carrot, crop})
            |> then(&%{&1 | data: %{&1.data | more_carrots: 40}})
          else
            self
          end

        {%{state | own: %{state.own | can_raid: false}, next: 10}, self}
      else
        {state, self}
      end
    end

    # `isValidTarget`: farmland under a grown carrot, while it wants food
    # and has not found one.
    defp valid(self, cell, %{own: own} = state) do
      {x, y, z} = cell

      with true <- own.wants and not own.can_raid,
           floor when floor != nil <- World.block(self.world, cell),
           true <- MapSet.member?(@supports, Blocks.block_id(floor)),
           crop when crop != nil <- World.block(self.world, {x, y + 1, z}),
           true <- carrot?(crop) and {"age", "7"} in Blocks.properties(crop) do
        {true, %{state | own: %{own | can_raid: true}}}
      else
        _ -> {false, state}
      end
    end

    defp carrot?(nil), do: false
    defp carrot?(state), do: Blocks.block_id(state) == @carrots
  end
end
