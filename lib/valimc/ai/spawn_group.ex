defmodule Valimc.AI.SpawnGroup do
  @moduledoc "Pure, bounded pack finalization state, consumed within group admission (VMC-043e9)."
  alias Valimc.AI.{Mobs.Fish, Mobs.TropicalFish, Spawn}
  alias Valimc.Entity.{Animal, Animals.Axolotl, Animals.Turtle}

  @types ~w(minecraft:axolotl minecraft:turtle minecraft:cod minecraft:salmon minecraft:tropical_fish minecraft:dolphin minecraft:squid minecraft:glow_squid)
  def handles?(type), do: type in @types

  @doc "Finalize one member. A supplied school decision belongs to the natural-spawn kernel."
  def finalize(self, group, school \\ nil) do
    reason = self.mob.finalize
    self = %{self | mob: %{self.mob | finalize: nil}}

    case self.type do
      "minecraft:axolotl" ->
        axolotl(self, group, reason)

      "minecraft:turtle" ->
        turtle(self, group, reason)

      "minecraft:dolphin" ->
        ageable(
          Valimc.AI.Mobs.Dolphin.spawn_part(self),
          group,
          reason,
          Animal.water_ageable(self.type).baby_chance
        )

      type when type in ["minecraft:squid", "minecraft:glow_squid"] ->
        ageable(self, group, reason, Animal.water_ageable(type).baby_chance)

      "minecraft:tropical_fish" ->
        tropical(self, group, reason, school)

      type when type in ["minecraft:cod", "minecraft:salmon"] ->
        school(Fish.finalize(self, reason), group)
    end
  end

  defp axolotl(self, group, :bucket), do: {self, group}

  defp axolotl(self, group, reason) do
    {group, self} =
      if group do
        {group, self}
      else
        common = Axolotl.common_variants()
        {a, self} = Spawn.level_int(self, length(common))
        {b, self} = Spawn.level_int(self, length(common))
        {%{count: 0, variants: {Enum.at(common, a), Enum.at(common, b)}}, self}
      end

    {i, self} = Spawn.level_int(self, 2)
    data = %{self.data | variant: elem(group.variants, i)}
    data = if group.count >= 2, do: %{data | age: -24_000}, else: data
    {Spawn.mob(%{self | data: data}, reason), %{group | count: group.count + 1}}
  end

  defp turtle(self, group, reason) do
    self = Turtle.spawn_part(self, reason)
    ageable(self, group, reason, Animal.group_baby_chance())
  end

  defp ageable(self, group, reason, chance) do
    group = group || %{count: 0}

    self =
      if group.count > 0 do
        {f, self} = Spawn.level_float(self)

        if f <= chance,
          do: %{self | data: %{self.data | age: -24_000}},
          else: self
      else
        self
      end

    {Spawn.mob(self, reason), %{group | count: group.count + 1}}
  end

  defp school(self, nil), do: {self, %{leader: self.uuid, count: 1, variant: nil}}

  defp school(self, group) do
    {Fish.follow(self, self.uuid, group.leader), %{group | count: group.count + 1}}
  end

  defp tropical(self, group, reason, decision) do
    self = Spawn.mob(self, reason)
    {self, group} = school(self, group)

    if group.variant != nil do
      {%{self | data: %{self.data | variant: group.variant}}, group}
    else
      {school, self} =
        if is_boolean(decision) do
          {decision, self}
        else
          {f, self} = Spawn.level_float(self)
          {f < Valimc.Data.Float32.round(0.9), self}
        end

      self = TropicalFish.spawn_variant(self, school)

      group =
        if school,
          do: %{group | leader: self.uuid, count: 1, variant: self.data.variant},
          else: group

      {self, group}
    end
  end
end
