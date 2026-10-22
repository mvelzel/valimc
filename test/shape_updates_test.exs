defmodule Valimc.ShapeUpdatesTest do
  @moduledoc "The shape updates `ShapeOracle` once excluded (VMC-029d), on the block-update engine."
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks

  defp step(floor, set) do
    rules = Valimc.World.BlockRules.native()
    floor = for {{x, y, z}, s} <- floor, do: {x, y, z, s}
    {x, y, z} = elem(set, 0)

    {:ok, [{writes, _destroyed, ticks}]} =
      Valimc.Native.rules_scene(rules, floor, [{x, y, z, elem(set, 1)}])

    {Map.new(writes, fn {x, y, z, s} -> {{x, y, z}, s} end), ticks}
  end

  test "an attached stem whose pumpkin goes becomes a grown stem" do
    stem = Blocks.state("attached_pumpkin_stem", %{"facing" => "east"})

    {writes, _} =
      step(
        %{
          {0, 63, 0} => Blocks.default_state("farmland"),
          {0, 64, 0} => stem,
          {1, 64, 0} => Blocks.default_state("pumpkin")
        },
        {{1, 64, 0}, 0}
      )

    assert writes[{0, 64, 0}] == Blocks.state("pumpkin_stem", %{"age" => "7"})
  end

  test "a kelp plant whose head goes becomes a head; an observer pulses at a change before it" do
    water = Blocks.default_state("water")
    plant = Blocks.default_state("kelp_plant")

    {writes, _} =
      step(
        %{
          {0, 63, 0} => Blocks.default_state("sand"),
          {0, 64, 0} => plant,
          {0, 65, 0} => Blocks.default_state("kelp")
        },
        {{0, 65, 0}, water}
      )

    assert Blocks.block_id(writes[{0, 64, 0}]) == Blocks.block_id(Blocks.default_state("kelp"))

    observer = Blocks.state("observer", %{"facing" => "east"})
    {_, ticks} = step(%{{0, 64, 0} => observer}, {{1, 64, 0}, Blocks.default_state("stone")})
    assert {0, 64, 0, Blocks.block_id(observer), 2} in ticks
  end
end
