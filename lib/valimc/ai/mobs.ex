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

  # The family modules (VMC-043b–e, `Valimc.AI.Kind`): each names its
  # `types/0` and gives its goals (`goals/1`) and, where it has them,
  # `finalize/2` (`Valimc.AI.Spawn`), its own data (`data/1`, `values/1`),
  # dimensions (`dimensions/1`) and the parts of vanilla's tick its class
  # overrides (`hook/4`). Farm animals (VMC-043c) are one module each over
  # `Valimc.Entity.Animal`.
  @families [
    Valimc.Entity.Dragon,
    Valimc.AI.Mobs.Zombie,
    Valimc.AI.Mobs.Skeleton,
    Valimc.AI.Mobs.Creeper,
    Valimc.AI.Mobs.Enderman,
    Valimc.AI.Mobs.Silverfish,
    Valimc.AI.Mobs.Slime,
    Valimc.AI.Mobs.Witch,
    Valimc.AI.Mobs.Phantom,
    Valimc.AI.Mobs.Drowned,
    Valimc.AI.Mobs.Spider,
    Valimc.AI.Mobs.ZombifiedPiglin,
    Valimc.AI.Mobs.Endermite,
    Valimc.AI.Mobs.Shulker,
    Valimc.AI.Mobs.Piglin,
    Valimc.AI.Mobs.Blaze,
    Valimc.AI.Mobs.Fish,
    Valimc.AI.Mobs.Pufferfish,
    Valimc.AI.Mobs.TropicalFish,
    Valimc.AI.Mobs.Squid,
    Valimc.AI.Mobs.Guardian,
    Valimc.AI.Mobs.Bat,
    Valimc.AI.Mobs.Ghast,
    Valimc.AI.Mobs.MagmaCube,
    Valimc.AI.Mobs.Villager,
    Valimc.AI.Mobs.IronGolem,
    Valimc.AI.Mobs.WanderingTrader,
    Valimc.AI.Mobs.Dolphin,
    Valimc.AI.Mobs.Hoglin,
    Valimc.AI.Mobs.WitherSkeleton
    | Valimc.Entity.Animal.modules()
  ]
  @family for module <- @families, type <- module.types(), into: %{}, do: {type, module}
  @exports for module <- @families,
               into: %{},
               do: {module, MapSet.new(module.__info__(:functions))}

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

  @types Map.keys(@family)

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

  @doc """
  `name` of the family module of `type` called with `args` where the module
  defines it (`Valimc.AI.Kind`'s optional callbacks), else `default`.
  """
  def hook(type, name, args, default) do
    module = @family[type]
    if exports?(module, name, length(args)), do: apply(module, name, args), else: default
  end

  @doc "Whether mobs of `type` keep their own air (`air/2` or `breath/1`), read before their AI."
  def own_air?(type) do
    module = @family[type]
    exports?(module, :air, 2) or exports?(module, :breath, 1)
  end

  @doc """
  A family's part of `doHurtTarget` after a melee hit of `target` (its
  `hit/2`: an `{:attack_extra, ref, extras}` effect), else `self`.
  """
  def hit(%{type: type} = self, target) do
    module = @family[type]
    if exports?(module, :hit, 2), do: module.hit(self, target), else: self
  end

  @doc "`wantsToPickUp` of an item id (a family's `wants?/2`, else `canHoldItem`)."
  def wants?(%{type: type} = self, item) do
    module = @family[type]
    if exports?(module, :wants?, 2), do: module.wants?(self, item), else: can_hold?(self, item)
  end

  @doc "`canHoldItem` of an item id (a family's `can_hold?/2`, else true)."
  def can_hold?(%{type: type} = self, item) do
    module = @family[type]
    if exports?(module, :can_hold?, 2), do: module.can_hold?(self, item), else: true
  end

  @doc "`getPreferredWeaponType`: a set of item ids, or nil."
  def preferred_weapons(type) do
    module = @family[type]
    if exports?(module, :preferred_weapons, 1), do: module.preferred_weapons(type)
  end

  @doc """
  A family's part of the tick after the move (`after_move/3` of `body` at
  `position` with the kernel's tick `ticked`): `{body, effects}`.
  """
  def after_move(%{type: type} = body, position, ticked) do
    module = @family[type]

    if exports?(module, :after_move, 3),
      do: module.after_move(body, position, ticked),
      else: {body, []}
  end

  @doc """
  A player's use of an item on a family's mob (`mobInteract`: its
  `mob_interact/2` of `body` and the request): as
  `Valimc.Entity.Animals.Interaction`, else `:pass`.
  """
  def interact(%{type: type} = body, request) do
    module = @family[type]
    if exports?(module, :mob_interact, 2), do: module.mob_interact(body, request), else: :pass
  end

  @doc "The base of a mob's voice pitch (`getVoicePitch`): a family's `voice/2`, else 1.0."
  def voice(type, data) do
    module = @family[type]
    if exports?(module, :voice, 2), do: module.voice(type, data), else: 1.0
  end

  defp exports?(nil, _name, _arity), do: false
  defp exports?(module, name, arity), do: MapSet.member?(@exports[module], {name, arity})

  @doc "The brain module of a brain mob's type, or nil (VMC-041a2)."
  def brain("minecraft:piglin"), do: Valimc.AI.Brains.Piglin
  def brain(type), do: hook(type, :brain, [], nil)

  @doc """
  The navigation a mob of `type` makes (`createNavigation`): its kind and
  abilities (`Navigation.new/2`). A piglin opens doors
  (`AbstractPiglin.applyOpenDoorsAbility`).
  """
  def navigation("minecraft:piglin"), do: {:ground, can_open_doors: true}
  def navigation(type), do: hook(type, :navigation, [], {:ground, []})

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
