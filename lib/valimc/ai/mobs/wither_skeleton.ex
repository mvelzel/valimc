defmodule Valimc.AI.Mobs.WitherSkeleton do
  @moduledoc """
  A wither skeleton (VMC-043d, vanilla's `WitherSkeleton`), a skeleton
  (`Valimc.AI.Mobs.Skeleton`'s goals and weapon goal) that also targets
  piglins, spawns with a stone sword and no armour or enchantments, hits
  for 4 and withers what it hits for ten seconds, and cannot be withered.
  Its arrows, when it holds a bow, burn.
  """
  @behaviour Valimc.AI.Kind

  alias Valimc.AI.{Goals, Self, Spawn, World}
  alias Valimc.AI.Mobs.Skeleton
  alias Valimc.Data.Float32
  alias Valimc.Protocol.ItemStack

  @type_name "minecraft:wither_skeleton"
  @wither Valimc.Data.EffectTypes.id("wither")
  @disliked MapSet.new(
              Valimc.Protocol.Data.tags()["minecraft:item"][
                "minecraft:wither_skeleton_disliked_weapons"
              ]
            )

  @impl true
  def types, do: [@type_name]

  @doc "`registerGoals`: piglins as targets first, then a skeleton's."
  @impl true
  def goals(type) do
    {goals, targets} = Skeleton.goals(type)

    piglins =
      {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
       Goals.NearestAttackableTarget.new(
         :mob,
         ["minecraft:piglin", "minecraft:piglin_brute"],
         true
       )}

    {goals, [piglins | targets]}
  end

  @doc """
  `finalizeSpawn`: a mob's own spawn, a stone sword (no armour, no
  enchantments), loot pickup by the special multiplier, a Halloween head,
  then an attack damage of 4.
  """
  @impl true
  def finalize(self, reason) do
    self = Spawn.mob(self, reason)
    special = Spawn.special(self)
    self = Spawn.equip(self, :mainhand, ItemStack.new("stone_sword"))
    {f, self} = Spawn.level_float(self)
    loot = f < Float32.round(Float32.round(0.55) * special)
    self = %{self | mob: %{self.mob | can_pick_up_loot: loot}}
    self |> Skeleton.halloween() |> Spawn.set_base("minecraft:attack_damage", 4.0)
  end

  @doc "`canHoldItem`: not a weapon it dislikes."
  @impl true
  def can_hold?(_self, item), do: not MapSet.member?(@disliked, item)

  @impl true
  def wants?(self, item), do: Skeleton.wants?(self, item)

  @doc "`getPreferredWeaponType`: none."
  @impl true
  def preferred_weapons(_type), do: nil

  @doc "`doHurtTarget`: what it hits is withered for ten seconds."
  @impl true
  def hit(%Self{} = self, target),
    do:
      Self.effect(
        self,
        {:attack_extra, World.ref(target), %{effect: {@wither, {200, 0, false, true, true}}}}
      )

  @doc "`canBeAffected`: never withered."
  @impl true
  def affected?(effect), do: effect != @wither
end
