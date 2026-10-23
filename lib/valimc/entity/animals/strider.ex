defmodule Valimc.Entity.Animals.Strider do
  @moduledoc """
  A strider (VMC-043d, vanilla's `Strider`), an animal: it walks on lava
  (the kernel's lava walker: lava sources hold it up, it travels as in air
  in lava and floats up out of it), heads for lava within eight blocks
  when out of it (`StriderGoToLavaGoal`), panics, breeds on and is tempted
  by warped fungus and follows its parent. Away from lava and other warm
  blocks it shivers (its suffocating flag) and slows by a third. Tempted it
  now and then sounds happy, panicking it retreats. Water hurts it.

  Riding with a saddle and a warped fungus on a stick, and the jockeys it
  may spawn with, wait for vehicles (VMC-046).
  """
  use Valimc.Entity.Animal, type: "minecraft:strider"
  alias Valimc.AI.{Goals, Selector, Self, World}
  alias Valimc.Data.Float32

  @strider "minecraft:strider"
  @speed "minecraft:movement_speed"
  @suffocating {"minecraft:suffocating", Float32.round(-0.34), 1}
  @tags Valimc.Protocol.Data.tags()
  @tempt MapSet.new(@tags["minecraft:item"]["minecraft:strider_tempt_items"])
  @warm for id <- @tags["minecraft:block"]["minecraft:strider_warm_blocks"],
            state <- Valimc.Data.Blocks.states(Valimc.Data.Blocks.name(id)),
            into: MapSet.new(),
            do: state

  @lava_fluid MapSet.new(Valimc.Data.Blocks.states("lava"))

  @impl true
  def goals do
    {[
       {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.65)},
       {2, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(1.0)},
       {3, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.4, &MapSet.member?(@tempt, &1), false)},
       {4, "StriderGoToLavaGoal", __MODULE__.GoToLava, [:move, :jump], __MODULE__.GoToLava.new()},
       {5, "FollowParentGoal", Goals.FollowParent, [], Goals.FollowParent.new(1.0)},
       {7, "RandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, interval: 60)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {9, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look],
        Goals.LookAtPlayer.new(8.0, 0.02, types: [@strider])}
     ], []}
  end

  @impl true
  def defaults, do: %{suffocating: false}

  @impl true
  def fields(data), do: [{:strider_suffocating, data.suffocating, false}]

  @impl true
  def offspring(self, _partner), do: {%{suffocating: false}, self}

  @impl Valimc.AI.Kind
  def motion, do: [lava_walker: true]

  @doc """
  `finalizeSpawn`'s own part for an adult: one time in thirty a zombified
  piglin rides it, else one time in ten a baby strider (the level's
  random; riders wait for vehicles).
  """
  @impl true
  def spawn_part(%Self{data: %{age: age}} = self, _reason) when age < 0, do: self

  def spawn_part(self, _reason) do
    {n, self} = Valimc.AI.Spawn.level_int(self, 30)

    if n == 0 do
      self
    else
      {_, self} = Valimc.AI.Spawn.level_int(self, 10)
      self
    end
  end

  @doc """
  `Strider.tick` before its super: tempted, a happy sound one tick in 140;
  panicking, a retreat one tick in 60; then whether it shivers: not in or
  on a warm block nor in lava.
  """
  @impl Valimc.AI.Kind
  def tick_start(%Self{} = self) do
    running = Selector.running(self, :goals)

    self =
      cond do
        Goals.Tempt in running ->
          {n, self} = Self.int(self, 140)
          if n == 0, do: Valimc.AI.make_sound(self, "minecraft:entity.strider.happy"), else: self

        Goals.Panic in running ->
          {n, self} = Self.int(self, 60)

          if n == 0,
            do: Valimc.AI.make_sound(self, "minecraft:entity.strider.retreat"),
            else: self

        true ->
          self
      end

    if self.mob.no_ai, do: self, else: shiver(self)
  end

  defp shiver(%Self{} = self) do
    inside = World.block(self.world, Self.block(self))

    # `getBlockStateOnLegacy`: through its supporting block, as its last move left it.
    on =
      self.mob.motion.support ||
        World.block(
          self.world,
          {floor(self.x), floor(self.y - Float32.round(0.2)), floor(self.z)}
        )

    warm =
      MapSet.member?(@warm, inside) or MapSet.member?(@warm, on) or Self.in_lava?(self)

    set_suffocating(self, not warm)
  end

  @doc "`setSuffocating`: its flag and a third less speed."
  def set_suffocating(%Self{mob: mob} = self, flag) do
    entry = Map.get(mob.attributes, @speed, %{base: nil, modifiers: []})
    modifiers = Enum.reject(entry.modifiers, &(elem(&1, 0) == elem(@suffocating, 0)))
    entry = %{entry | modifiers: if(flag, do: modifiers ++ [@suffocating], else: modifiers)}

    attributes =
      if entry == %{base: nil, modifiers: []},
        do: Map.delete(mob.attributes, @speed),
        else: Map.put(mob.attributes, @speed, entry)

    %{self | data: %{self.data | suffocating: flag}, mob: %{mob | attributes: attributes}}
  end

  @doc "`getAmbientSound`: none while panicking or tempted."
  @impl Valimc.AI.Kind
  def ambient_sound(self) do
    running = Selector.running(self, :goals)

    if Goals.Panic in running or Goals.Tempt in running,
      do: nil,
      else: "minecraft:entity.strider.ambient"
  end

  @doc "`getWalkTargetValue`: lava is worth 10; out of it, only lava is worth anything."
  @impl Valimc.AI.Kind
  def walk_value(self, cell) do
    cond do
      MapSet.member?(@lava_fluid, World.block(self.world, cell)) -> 10.0
      Self.in_lava?(self) -> :neg_infinity
      true -> 0.0
    end
  end
end

defmodule Valimc.Entity.Animals.Strider.GoToLava do
  @moduledoc """
  `Strider.StriderGoToLavaGoal` (`MoveToBlockGoal` at 1.0, eight blocks
  around and two up or down): out of lava, to a lava block with room to
  stand above it; it walks to the lava block itself (recalculating every
  20 ticks toward that block, not the one above it).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.MoveToBlock

  def new, do: MoveToBlock.new(1.0, 8, &valid/3, vertical: 2)

  def every_tick?(_state), do: true

  def can_use(state, self) do
    if Self.in_lava?(self), do: {false, state, self}, else: MoveToBlock.can_use(state, self)
  end

  def can_continue(state, self) do
    {valid, state} = valid(self, state.cell, state)
    {not Self.in_lava?(self) and valid, state, self}
  end

  defdelegate start(state, self), to: MoveToBlock

  # `MoveToBlockGoal.tick` toward the lava block itself.
  def tick(state, self) do
    {x, y, z} = state.cell
    {dx, dy, dz} = {x + 0.5 - self.x, y + 0.5 - self.y, z + 0.5 - self.z}

    if dx * dx + dy * dy + dz * dz < 1.0 do
      {%{state | reached: true, tries: state.tries - 1}, self}
    else
      tries = state.tries + 1

      self =
        if rem(tries, 20) == 0 do
          {_, self} = Navigation.move_to(self, {x + 0.5, y * 1.0, z + 0.5}, state.speed)
          self
        else
          self
        end

      {%{state | reached: false, tries: tries}, self}
    end
  end

  @lava MapSet.new(Valimc.Data.Blocks.states("lava"))

  # `isValidTarget`: lava with room for a land walker above.
  defp valid(self, {x, y, z} = cell, state) do
    lava = MapSet.member?(@lava, World.block(self.world, cell))
    above = World.block(self.world, {x, y + 1, z})
    {lava and Valimc.AI.Facts.land_pathfindable?(above), state}
  end
end
