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

  # The family modules (VMC-043b–e): each names its `types/0` and gives its
  # goals (`goals/1`) and, where it has them, `finalize/2` (`Valimc.AI.Spawn`),
  # its own data (`data/1`, `values/1`) and dimensions (`dimensions/1`).
  @families [Valimc.AI.Mobs.Zombie, Valimc.AI.Mobs.ZombifiedPiglin]
  @family for module <- @families, type <- module.types(), into: %{}, do: {type, module}
  @exports for module <- @families,
               into: %{},
               do: {module, MapSet.new(module.__info__(:functions))}

  @pig_food MapSet.new(Data.tags()["minecraft:item"]["minecraft:pig_food"])
  @carrot_on_a_stick ItemTypes.id("minecraft:carrot_on_a_stick")

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

  def registered("minecraft:piglin"), do: {[], []}
  def registered("minecraft:blaze"), do: Valimc.AI.Mobs.Blaze.registered()

  def registered(type) when is_map_key(@family, type), do: @family[type].goals(type)

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

  @types [
    "minecraft:pig",
    "minecraft:piglin",
    "minecraft:blaze" | Map.keys(@family)
  ]

  @doc "The family module of `type`, or nil."
  def family(type), do: @family[type]

  @doc "The module whose `finalize/2` finishes a spawn of `type`, or nil (`Valimc.AI.Spawn`)."
  def finalizer(type) do
    module = @family[type]
    if exports?(module, :finalize, 2), do: module
  end

  @doc "The own data of a body of `type` its family keeps, or nil."
  def data(type) do
    module = @family[type]
    if exports?(module, :data, 1), do: module.data(type)
  end

  @doc "The own entity data values of `body` (`[{field, value, default}]`)."
  def values(%{type: type} = body) do
    module = @family[type]
    if exports?(module, :values, 1), do: module.values(body), else: []
  end

  @doc "`body`'s dimensions `{width, height, eye}` where its family changes them, else nil."
  def dimensions(%{type: type} = body) do
    module = @family[type]
    if exports?(module, :dimensions, 1), do: module.dimensions(body)
  end

  defp exports?(nil, _name, _arity), do: false
  defp exports?(module, name, arity), do: MapSet.member?(@exports[module], {name, arity})

  @doc """
  The module of a type's own `customServerAiStep` (`custom_step/1`, after
  its navigation) and ambient sound (`ambient_sound/1`), or nil: a family's
  mob that does more than its goals.
  """
  def custom("minecraft:blaze"), do: Valimc.AI.Mobs.Blaze
  def custom("minecraft:zombified_piglin"), do: Valimc.AI.Mobs.ZombifiedPiglin
  def custom(_type), do: nil

  @doc "The module of a type's own `setTarget` (`set_target/2`), or nil."
  def on_target("minecraft:zombified_piglin"), do: Valimc.AI.Mobs.ZombifiedPiglin
  def on_target(_type), do: nil

  @doc "The brain module of a brain mob's type, or nil (VMC-041a2)."
  def brain("minecraft:piglin"), do: Valimc.AI.Brains.Piglin
  def brain(_type), do: nil

  @doc """
  The navigation a mob of `type` makes (`createNavigation`): its kind and
  abilities (`Navigation.new/2`). A piglin opens doors
  (`AbstractPiglin.applyOpenDoorsAbility`).
  """
  def navigation("minecraft:piglin"), do: {:ground, can_open_doors: true}
  def navigation(_type), do: {:ground, []}

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
