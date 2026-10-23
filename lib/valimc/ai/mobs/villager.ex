defmodule Valimc.AI.Mobs.Villager do
  @moduledoc """
  `Villager` (VMC-044a1): no goals, a brain (`Valimc.AI.Brains.Villager`),
  a navigation that opens doors, floats and paths 48 blocks, and its own
  data (`Valimc.Entity.Villager`: `VillagerData`, age, the bed it lies in).
  """
  @behaviour Valimc.AI.Kind

  @impl true
  def types, do: ["minecraft:villager"]

  @impl true
  def goals(_type), do: {[], []}

  @impl true
  def brain, do: Valimc.AI.Brains.Villager

  # Its constructor: `setCanOpenDoors`, `setCanFloat`, `setRequiredPathLength(48)`.
  @impl true
  def navigation, do: {:ground, can_open_doors: true, can_float: true, required_length: 48.0}

  @impl true
  def data(_type), do: Valimc.Entity.Villager.data()

  @impl true
  def values(%{data: data}), do: Valimc.Entity.Villager.values(data)
end
