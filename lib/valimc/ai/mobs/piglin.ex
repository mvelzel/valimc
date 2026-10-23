defmodule Valimc.AI.Mobs.Piglin do
  @moduledoc """
  A piglin as a mob family (VMC-043d, vanilla's `Piglin`): its own data and
  entity data (baby, immune to zombification, charging a crossbow,
  dancing, and whether it may hunt), a baby's size and speed, and its spawn
  (`finalizeSpawn`): one time in five a baby, else a crossbow or a golden
  sword (a golden spear one time in ten), the wait before its first hunt,
  gold armour piece by piece one time in ten, their enchantments, then a
  mob's own spawn. A piglin from a structure (a bastion) is neither.

  Its brain is `Valimc.AI.Brains.Piglin`; it registers no goals.
  """
  alias Valimc.AI.{Brain, Self, Spawn}
  alias Valimc.Data.{Float32, HostileFacts}
  alias Valimc.Protocol.ItemStack

  @piglin "minecraft:piglin"
  @speed "minecraft:movement_speed"
  @baby_speed {"minecraft:baby", Float32.round(0.2), 1}

  @behaviour Valimc.AI.Kind

  @impl true
  def types, do: [@piglin]

  @doc "A brain mob registers no goals."
  @impl true
  def goals(_type), do: {[], []}

  @doc "Its own data."
  @impl true
  def data(_type),
    do: %{baby: false, immune: false, charging: false, dancing: false, cannot_hunt: false}

  @doc "Its entity data values: `[{field, value, default}]`."
  @impl true
  def values(%{data: data}),
    do: [
      {:piglin_immune, data.immune, false},
      {:piglin_baby, data.baby, false},
      {:piglin_charging_crossbow, data.charging, false},
      {:piglin_dancing, data.dancing, false}
    ]

  @doc "A baby's dimensions, or nil."
  @impl true
  def dimensions(%{data: %{baby: true}}), do: HostileFacts.baby(@piglin)
  def dimensions(_body), do: nil

  @doc "`getVoicePitch`'s base: a baby's is higher."
  @impl true
  def voice(_type, %{baby: true}), do: 1.5
  def voice(_type, _data), do: 1.0

  @doc "`isBaby`."
  def baby?(%{data: %{baby: baby}}), do: baby
  def baby?(_body), do: false

  @doc "`Piglin.finalizeSpawn`."
  @impl true
  def finalize(%Self{} = self, reason) do
    # A piglin picks up loot from the start (`AbstractPiglin`'s constructor).
    self = %{self | mob: %{self.mob | can_pick_up_loot: true}}

    self =
      if reason != :structure do
        {f, self} = Spawn.level_float(self)
        if f < Float32.round(0.2), do: set_baby(self, true), else: weapon(self)
      else
        self
      end

    # `PiglinAi.initMemories`: no hunt for 30 to 120 seconds.
    {n, self} = Spawn.level_int(self, 1801)
    self = if self.mind.brain, do: Brain.set(self, :hunted_recently, true, 600 + n), else: self

    self
    |> armour()
    |> Spawn.enchant_equipment()
    |> Spawn.mob(reason)
  end

  # `createSpawnWeapon`, from its own random.
  defp weapon(self) do
    {f, self} = Self.float(self)

    {item, self} =
      if f < 0.5 do
        {"crossbow", self}
      else
        {n, self} = Self.int(self, 10)
        {if(n == 0, do: "golden_spear", else: "golden_sword"), self}
      end

    Spawn.equip(self, :mainhand, ItemStack.new(item))
  end

  # `populateDefaultEquipmentSlots`: an adult's gold armour, each piece one
  # time in ten.
  defp armour(%Self{data: %{baby: true}} = self), do: self

  defp armour(self) do
    [
      head: "golden_helmet",
      chest: "golden_chestplate",
      legs: "golden_leggings",
      feet: "golden_boots"
    ]
    |> Enum.reduce(self, fn {slot, item}, self ->
      {f, self} = Spawn.level_float(self)

      if f < Float32.round(0.1),
        do: Spawn.equip(self, slot, ItemStack.new(item)),
        else: self
    end)
  end

  @doc "`setBaby`: the flag and the baby speed modifier."
  def set_baby(%Self{mob: mob} = self, baby) do
    entry = Map.get(mob.attributes, @speed, %{base: nil, modifiers: []})
    modifiers = Enum.reject(entry.modifiers, &(elem(&1, 0) == "minecraft:baby"))
    entry = %{entry | modifiers: if(baby, do: modifiers ++ [@baby_speed], else: modifiers)}

    attributes =
      if entry == %{base: nil, modifiers: []},
        do: Map.delete(mob.attributes, @speed),
        else: Map.put(mob.attributes, @speed, entry)

    %{self | data: Map.put(self.data, :baby, baby), mob: %{mob | attributes: attributes}}
  end
end
