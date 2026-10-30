defmodule Valimc.NativeMobStandUpTest do
  @moduledoc """
  VMC-081d: where a native villager gets up from its bed (the native
  `StandUp.bed`) equals `Valimc.World.StandUp.bed/4` over random scenes:
  beds of each facing (some on another bed), floors, slabs, carpets,
  walls, fire, magma and cacti around them, any yaw.
  """
  use ExUnit.Case, async: true

  alias Valimc.Data.Blocks
  alias Valimc.Entity.NativeMobs
  alias Valimc.Native
  alias Valimc.World.{StandUp, View}

  setup_all do
    Valimc.Data.BlockFacts.install!()
    NativeMobs.install!()
    :ok
  end

  @facings [:north, :south, :west, :east]

  defp scene(seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 5})
    stone = Blocks.default_state("stone")

    around = [
      Blocks.default_state("air"),
      Blocks.default_state("air"),
      Blocks.default_state("air"),
      stone,
      Blocks.default_state("oak_slab"),
      Blocks.default_state("white_carpet"),
      Blocks.default_state("fire"),
      Blocks.default_state("magma_block"),
      Blocks.default_state("cactus"),
      Blocks.default_state("water"),
      Blocks.default_state("oak_fence"),
      Blocks.default_state("cobweb")
    ]

    floor =
      for x <- -7..7, y <- 62..69, z <- -7..7, into: %{} do
        {{x, y, z}, if(y <= 63, do: stone, else: Blocks.default_state("air"))}
      end

    cells =
      for x <- -4..4, y <- 64..66, z <- -4..4, :rand.uniform() < 0.35, into: %{} do
        {{x, y, z}, Enum.random(around)}
      end

    facing = Enum.random(@facings)
    bed = Blocks.state("red_bed", %{"facing" => Atom.to_string(facing), "part" => "head"})
    bunk = :rand.uniform() < 0.25
    head = {0, if(bunk, do: 65, else: 64), 0}
    blocks = floor |> Map.merge(cells) |> Map.put(head, bed)
    blocks = if bunk, do: Map.put(blocks, {0, 64, 0}, bed), else: blocks
    yaw = :rand.uniform() * 720.0 - 360.0
    {blocks, head, facing, yaw}
  end

  test "the native stand-up equals StandUp.bed/4" do
    found =
      for seed <- 1..400, reduce: 0 do
        found ->
          {blocks, {x, y, z} = head, facing, yaw} = scene(seed)
          expected = StandUp.bed(View.of(blocks), head, facing, yaw)

          packed =
            for {{bx, by, bz}, state} <- blocks,
                into: <<>>,
                do: <<bx::32-signed, by::32-signed, bz::32-signed, state::16>>

          index = Enum.find_index(@facings, &(&1 == facing))
          got = Native.mob_stand_up_parity({:states, packed}, {x, y, z}, index, yaw)
          assert got == expected, "scene #{seed}: #{inspect(got)} != #{inspect(expected)}"
          if expected, do: found + 1, else: found
      end

    assert found > 100
  end
end
