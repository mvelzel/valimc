defmodule Valimc.Blocks.Harvest do
  @moduledoc """
  Berries a player picks by using the block (VMC-039b): a sweet berry bush
  past age 1 (`SweetBerryBushBlock.useWithoutItem`) and cave vines with
  berries (`CaveVines.use`). The block rules pick them (`{:harvest,
  position}`); the owner drops what the block-interaction loot table gives
  (`priv/loot/tables.json`, `LootOracle facts`), each stack popped from the
  cell, and plays the pick sound to everyone near.
  """
  alias Valimc.Data.Blocks

  @bone_meal Valimc.Protocol.Data.item("bone_meal")
  @sweet_berries Blocks.id("sweet_berry_bush")
  @cave_vines MapSet.new([Blocks.id("cave_vines"), Blocks.id("cave_vines_plant")])

  @doc """
  What picking `state` with `item` in the main hand (its id, or nil) does:
  `{:ok, %{table: loot table, sound: sound id, pitch: pitch}}`, or `:none`
  (no berries; a growing bush gives way to bone meal, `useItemOn`'s pass).
  """
  def of(state, item) do
    block = Blocks.block_id(state)
    properties = Map.new(Blocks.properties(state))

    cond do
      block == @sweet_berries ->
        age = String.to_integer(properties["age"])

        if age > 1 and not (age < 3 and item == @bone_meal),
          do: picked("minecraft:harvest/sweet_berry_bush", "sweet_berry_bush"),
          else: :none

      MapSet.member?(@cave_vines, block) and properties["berries"] == "true" ->
        picked("minecraft:harvest/cave_vine", "cave_vines")

      true ->
        :none
    end
  end

  # Both pitches lie between 0.8 and 1.2 (`0.8 + nextFloat() * 0.4`,
  # `Mth.randomBetween`).
  defp picked(table, sound),
    do:
      {:ok,
       %{
         table: table,
         sound: "minecraft:block.#{sound}.pick_berries",
         pitch: 0.8 + :rand.uniform() * 0.4
       }}
end
