defmodule Valimc.AI.Mobs do
  @moduledoc """
  The goals each modelled mob registers (`registerGoals`), in vanilla's
  order with its priorities and flags. Compiling checks every list against
  the goals `MobAiOracle facts` read from vanilla's own selectors. Families
  (VMC-043b–e) add their types here.
  """
  alias Valimc.AI.{Facts, Selector}

  @doc """
  `{goals, targets}` a mob of `type` registers, each `{priority, vanilla
  goal, module, flags, state}`, or nil for a type without goals.
  """
  def registered(type)
  alias Valimc.AI.Goals
  alias Valimc.Protocol.{Data, ItemTypes}

  @zombies [
    "minecraft:zombie",
    "minecraft:husk",
    "minecraft:drowned",
    "minecraft:zombie_villager"
  ]
  @villagers ["minecraft:villager", "minecraft:wandering_trader"]
  @pig_food MapSet.new(Data.tags()["minecraft:item"]["minecraft:pig_food"])
  @carrot_on_a_stick ItemTypes.id("minecraft:carrot_on_a_stick")
  @turtle_eggs Enum.to_list(Valimc.Data.Blocks.states("turtle_egg"))

  def registered("minecraft:zombie") do
    {[
       {4, "ZombieAttackTurtleEggGoal", Goals.RemoveBlock, [:move, :jump],
        Goals.RemoveBlock.new(@turtle_eggs)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {2, "SpearUseGoal", Goals.Idle, [:move, :look], Goals.Idle.new("SpearUseGoal")},
       {3, "ZombieAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false, raise_arms: true)},
       {6, "MoveThroughVillageGoal", Goals.Idle, [:move],
        Goals.Idle.new("MoveThroughVillageGoal")},
       {7, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: @zombies)},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, @villagers, false)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:iron_golem"], true)},
       # `Turtle.BABY_ON_LAND_SELECTOR`: turtles are VMC-043e's.
       {5, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:turtle"], true, interval: 10)}
     ]}
  end

  def registered("minecraft:pig") do
    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.25)},
       {3, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(1.0)},
       {4, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.2, &(&1 == @carrot_on_a_stick), false)},
       {4, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.2, &MapSet.member?(@pig_food, &1), false)},
       {5, "FollowParentGoal", Goals.FollowParent, [], Goals.FollowParent.new(1.1)},
       {6, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {7, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ], []}
  end

  def registered(_type), do: nil

  @after_compile __MODULE__

  @doc false
  def __after_compile__(_env, _bytecode) do
    case differing() do
      [] -> :ok
      types -> raise "goals differ from vanilla's (MobAiOracle facts) for #{inspect(types)}"
    end
  end

  @doc "The types with AI facts whose registered goals are not vanilla's."
  def differing do
    shape = fn list -> for {p, name, _, flags, _} <- list, do: {p, name, flags} end

    for type <- Facts.mobs(),
        {goals, targets} = registered(type) || {[], []},
        facts = Facts.mob(type),
        shape.(goals) != facts.goals or shape.(targets) != facts.targets,
        do: type
  end

  @types ["minecraft:zombie", "minecraft:pig"]

  @doc "Whether mobs of `type` have goals."
  def goals?(type), do: type in @types

  @doc """
  The goal and target selectors of a fresh mob of `type`, and whether its
  navigation floats (a `FloatGoal` sets it when registered).
  """
  def selectors(type) do
    {goals, targets} = registered(type)

    entry = fn {priority, _, module, flags, state} ->
      Selector.goal(priority, module, flags, state)
    end

    {goals |> Enum.map(entry) |> List.to_tuple(), targets |> Enum.map(entry) |> List.to_tuple(),
     Enum.any?(goals, &(elem(&1, 2) == Goals.Float))}
  end
end
