defmodule Valimc.AI.Mobs.Skeleton do
  @moduledoc """
  Skeletons, strays and bogged (VMC-043b3), as vanilla's `AbstractSkeleton`
  and its kinds:

  - **Goals**: keeping out of the sun by day and fleeing it when burning,
    fleeing wolves, wandering and looking around; a bow goal while it holds
    a bow, else melee (`reassessWeaponGoal`: one weapon goal, last in order,
    that changes with what it holds); the player, iron golems and baby
    turtles as targets.
  - **Spawning**: armour, a bow, their enchantments, loot pickup and a
    Halloween head.
  - **Shooting** (`performRangedAttack`): an arrow through VMC-037o, slowing
    from a stray and poisoning from a bogged; bogged draw slower.
  - **Freezing**: a skeleton in powder snow for seven seconds shakes and
    becomes a stray fifteen seconds later.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Self, Spawn}
  alias Valimc.Data.Float32
  alias Valimc.Protocol.ItemStack

  @skeleton "minecraft:skeleton"
  @stray "minecraft:stray"
  @bogged "minecraft:bogged"
  @types [@skeleton, @stray, @bogged]

  @wolves ["minecraft:wolf"]
  @spears MapSet.new(Valimc.Protocol.Data.tags()["minecraft:item"]["minecraft:spears"])
  @preferred MapSet.new(
               Valimc.Protocol.Data.tags()["minecraft:item"][
                 "minecraft:skeleton_preferred_weapons"
               ]
             )

  @impl true
  def types, do: @types

  ## Goals

  @impl true
  def goals(_type) do
    {[
       {2, "RestrictSunGoal", Goals.RestrictSun, [], Goals.RestrictSun.new()},
       {3, "FleeSunGoal", Goals.FleeSun, [:move], Goals.FleeSun.new(1.0)},
       {3, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :mob and &1.type in @wolves), 6.0, 1.0, 1.2)},
       {5, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {6, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {6, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       # Added by `reassessWeaponGoal` as it is made: melee until it holds a bow.
       {4, "MeleeAttackGoal", __MODULE__.Weapon, [:move, :look], __MODULE__.Weapon.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target], Goals.HurtByTarget.new()},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:iron_golem"], true)},
       # `Turtle.BABY_ON_LAND_SELECTOR`: turtles are VMC-043e's.
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:turtle"], true, interval: 10)}
     ]}
  end

  @doc "The bow goal's least interval on hard and otherwise (`getHardAttackInterval`)."
  def intervals(@bogged), do: {50, 70}
  def intervals(_type), do: {20, 40}

  ## Data

  @impl true
  def data(@skeleton), do: %{in_snow: 0, converting: false, conversion: -1}
  def data(@bogged), do: %{sheared: false}
  def data(_type), do: %{}

  @impl true
  def values(%{type: @skeleton, data: data}),
    do: [{:skeleton_stray_conversion, data.converting, false}]

  def values(%{type: @bogged, data: data}), do: [{:bogged_sheared, data.sheared, false}]
  def values(_body), do: []

  ## Spawning

  @impl true
  def finalize(self, reason) do
    self = Spawn.mob(self, reason)
    special = Spawn.special(self)

    # `populateDefaultEquipmentSlots`: armour, then a bow.
    self =
      self
      |> Spawn.armour()
      |> Spawn.equip(:mainhand, ItemStack.new("bow"))
      |> Spawn.enchant_equipment()

    {f, self} = Spawn.level_float(self)
    loot = f < Float32.round(Float32.round(0.55) * special)
    self = %{self | mob: %{self.mob | can_pick_up_loot: loot}}
    halloween(self)
  end

  defp halloween(self) do
    if self.mob.equipment[:head] == nil and self.world.halloween do
      {f, self} = Spawn.level_float(self)

      if f < Float32.round(0.25) do
        {g, self} = Spawn.level_float(self)
        item = if g < Float32.round(0.1), do: "jack_o_lantern", else: "carved_pumpkin"
        self = Spawn.equip(self, :head, ItemStack.new(item))
        %{self | mob: Valimc.Entity.Mob.put_drop_chance(self.mob, :head, 0.0)}
      else
        self
      end
    else
      self
    end
  end

  ## Loot

  @impl true
  def wants?(_self, item), do: not MapSet.member?(@spears, item)

  @impl true
  def preferred_weapons(_type), do: @preferred

  ## Freezing

  @doc """
  `Skeleton.tick`'s freezing tracker before the rest of its tick
  (`ConversionTracker` over `isInPowderSnow` as its last move left it): 140
  ticks in powder snow start the conversion, 300 more turn it into a stray
  (`{:convert, type}` and the level event 1048).
  """
  @impl true
  def tick_start(%Self{type: @skeleton, data: data, mob: mob} = self) do
    cond do
      mob.no_ai ->
        self

      mob.motion.powder_snow and data.converting ->
        conversion = data.conversion - 1
        self = %{self | data: %{data | conversion: conversion}}

        if conversion < 0,
          do:
            self
            |> Self.effect({:convert, @stray})
            |> Self.effect({:level_event, Self.block(self), 1048, 0}),
          else: self

      mob.motion.powder_snow ->
        in_snow = data.in_snow + 1

        if in_snow >= 140,
          do: %{self | data: %{data | in_snow: in_snow, converting: true, conversion: 300}},
          else: %{self | data: %{data | in_snow: in_snow}}

      true ->
        %{self | data: %{data | in_snow: -1, converting: false}}
    end
  end

  def tick_start(self), do: self

  @doc "The effect the type's arrows carry (`getArrow`): `{effect, ticks}` or nil."
  def arrow_effect(@stray), do: {"slowness", 600}
  def arrow_effect(@bogged), do: {"poison", 100}
  def arrow_effect(_type), do: nil
end

defmodule Valimc.AI.Mobs.Skeleton.Weapon do
  @moduledoc """
  A skeleton's weapon goal (`AbstractSkeleton.reassessWeaponGoal`): the bow
  goal (`RangedBowAttackGoal` at its type's interval) while it holds a bow,
  else melee (`MeleeAttackGoal` at 1.2, raising its arms while it runs).
  Vanilla swaps the two goals at the end of the list as the weapon changes;
  one goal that follows the weapon keeps that order, stopping the running
  one when the weapon changes. `vanilla_name` is the goal it stands for.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.{MeleeAttack, RangedBowAttack}
  alias Valimc.AI.Mobs.Skeleton

  @bow Valimc.Protocol.ItemTypes.id("bow")

  def new,
    do: %{
      mode: :melee,
      vanilla_name: "MeleeAttackGoal",
      melee: MeleeAttack.new(1.2, false),
      bow: RangedBowAttack.new(1.0, 20, 15.0)
    }

  defp mode(self) do
    held = fn slot -> match?(%{item_id: @bow}, self.mob.equipment[slot]) end
    if held.(:mainhand) or held.(:offhand), do: :bow, else: :melee
  end

  # The goal for what it holds now, at the type's interval for the difficulty.
  defp current(state, self) do
    mode = mode(self)
    {hard, normal} = Skeleton.intervals(self.type)
    interval = if self.world.difficulty == :hard, do: hard, else: normal
    bow = RangedBowAttack.interval(state.bow, interval)

    name = if mode == :bow, do: "RangedBowAttackGoal", else: "MeleeAttackGoal"
    %{state | mode: mode, vanilla_name: name, bow: bow}
  end

  defp sub(%{mode: :bow}), do: {RangedBowAttack, :bow}
  defp sub(%{mode: :melee}), do: {MeleeAttack, :melee}

  defp call(state, self, fun) do
    {module, key} = sub(state)

    case apply(module, fun, [Map.fetch!(state, key), self]) do
      {flag, inner, self} when is_boolean(flag) -> {flag, Map.put(state, key, inner), self}
      {inner, self} -> {Map.put(state, key, inner), self}
    end
  end

  def can_use(state, self), do: call(current(state, self), self, :can_use)

  def can_continue(state, self) do
    if mode(self) != state.mode, do: {false, state, self}, else: call(state, self, :can_continue)
  end

  def start(state, self), do: call(state, self, :start)
  def stop(state, self), do: call(state, self, :stop)
  def tick(state, self), do: call(state, self, :tick)
  def every_tick?(_state), do: true
end
