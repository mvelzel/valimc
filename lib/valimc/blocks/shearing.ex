defmodule Valimc.Blocks.Shearing do
  @moduledoc """
  Shears a player uses on a block (VMC-039c): a full beehive or bee nest
  gives up its honeycomb and empties (`BeehiveBlock.useItemOn`), a pumpkin
  is carved and drops its seeds toward the player (`PumpkinBlock.useItemOn`).
  The block rules change the block (`{:shear, position, facing}`); the owner
  drops what the block-interaction loot table gives (`priv/loot/tables.json`)
  and plays the sound to everyone near; the shears wear in the player's
  process.

  Not modelled: the bees a hive releases and the bees it angers (no bees yet),
  a glass bottle's honey, and the `shear` game event.
  """
  alias Valimc.Data.Blocks
  import Bitwise, only: [band: 2, bxor: 2]

  @shears Valimc.Protocol.Data.item("shears")
  @hives MapSet.new([Blocks.id("beehive"), Blocks.id("bee_nest")])
  @pumpkin Blocks.id("pumpkin")

  @doc """
  What shears (`item`, the used hand's item id) do to `state`, clicked on
  face `face` (0..5) by a player at yaw `yaw`: `{:ok, %{table: loot table,
  sound: sound id, facing: direction index, carved: boolean}}`, or `:none`.
  A pumpkin is carved toward the clicked side, or toward the player when
  clicked from above or below.
  """
  def of(state, item, face, yaw) when item == @shears and is_integer(face) do
    block = Blocks.block_id(state)

    cond do
      MapSet.member?(@hives, block) and honey(state) >= 5 ->
        {:ok,
         %{
           table: "minecraft:harvest/beehive",
           sound: "minecraft:block.beehive.shear",
           facing: face,
           carved: false
         }}

      block == @pumpkin ->
        facing =
          if face >= 2,
            do: face,
            else: bxor(Enum.at([3, 4, 2, 5], band(floor((yaw || 0.0) / 90.0 + 0.5), 3)), 1)

        {:ok,
         %{
           table: "minecraft:carve/pumpkin",
           sound: "minecraft:block.pumpkin.carve",
           facing: facing,
           carved: true
         }}

      true ->
        :none
    end
  end

  def of(_state, _item, _face, _yaw), do: :none

  defp honey(state),
    do:
      state
      |> Blocks.properties()
      |> Map.new()
      |> Map.get("honey_level", "0")
      |> String.to_integer()
end
