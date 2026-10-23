defmodule Valimc.TurtleEggTest do
  @moduledoc "Turtle eggs (VMC-043e): the night's hatch chance, cracking, hatching and crushing."
  use ExUnit.Case, async: true
  alias Valimc.Blocks.TurtleEgg
  alias Valimc.Data.Blocks

  @sand Blocks.default_state("sand")

  test "the overworld hatches all through its dawn and seldom otherwise" do
    assert Valimc.World.Spawning.turtle_hatch_chance("minecraft:overworld", 21_500) == 1.0

    assert Valimc.World.Spawning.turtle_hatch_chance("minecraft:overworld", 6000) ==
             Valimc.Data.Float32.round(0.002)
  end

  test "eggs on sand crack, then hatch one baby turtle each at home" do
    # At night (a chance of 1) every random tick on sand advances the eggs.
    read = fn {_, 63, _} -> @sand end
    cracked = Blocks.state("turtle_egg", %{"eggs" => "1", "hatch" => "0"})

    assert [{:sound, _, "minecraft:entity.turtle.egg_crack", 0.7, _}, {:set, {0, 64, 0}, next}] =
             TurtleEgg.hatch({0, 64, 0}, cracked, read, 1.0)

    assert next == Blocks.state("turtle_egg", %{"eggs" => "1", "hatch" => "1"})

    ripe = Blocks.state("turtle_egg", %{"eggs" => "3", "hatch" => "2"})
    effects = TurtleEgg.hatch({0, 64, 0}, ripe, read, 1.0)
    mobs = for {:mob, "minecraft:turtle", at, opts} <- effects, do: {at, opts.data}
    assert length(mobs) == 3
    assert {{0.3, 64.0, 0.3}, %{age: -24_000, home: {0, 64, 0}}} = hd(mobs)
    assert {:set, {0, 64, 0}, Blocks.default_state("air")} in effects
    assert [] == TurtleEgg.hatch({0, 64, 0}, ripe, fn _ -> Blocks.default_state("stone") end, 1.0)
  end

  test "crushing at even odds always takes an egg; the last takes the block" do
    two = Blocks.state("turtle_egg", %{"eggs" => "2", "hatch" => "0"})
    assert {one, _} = TurtleEgg.crush(two, 1)
    assert one == Blocks.state("turtle_egg", %{"eggs" => "1", "hatch" => "0"})
    assert {air, _} = TurtleEgg.crush(one, 1)
    assert air == Blocks.default_state("air")
  end
end
