defmodule Valimc.Blocks.TurtleEgg do
  @moduledoc """
  Turtle eggs (`TurtleEggBlock`, VMC-043e). On sand, a random tick cracks
  them (by the dimension's hatch chance: 0.002, or every tick of the
  overworld's dawn, its timeline's 21062 to 21905) and after two cracks
  they hatch: one baby turtle for each egg, at home where they hatched, with
  the hatch sound and the block's break event for each. Trampling is
  `crush/2`.
  """
  use Valimc.Blocks.Behaviour
  alias Valimc.Data.{Blocks, Float32}

  @sand MapSet.new(Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:sand"])

  @doc "A random tick with the region's `context` (its `hatch_chance`)."
  @impl true
  def random_tick(position, state, read, _random, %{hatch_chance: chance}),
    do: hatch(position, state, read, chance)

  @impl true
  def random_tick(position, state, read, random),
    do: random_tick(position, state, read, random, %{hatch_chance: 0.002})

  @doc """
  `randomTick` at hatch chance `chance`: the effects (crack or hatch) when
  the level's random falls under it on sand, else none.
  """
  def hatch({x, y, z} = position, state, read, chance) do
    if chance > 0.0 and Float32.round(:rand.uniform_real()) < chance and
         sand?(read.({x, y - 1, z})) do
      props = Map.new(Blocks.properties(state))
      hatch = String.to_integer(props["hatch"])
      eggs = String.to_integer(props["eggs"])

      if hatch < 2 do
        [
          {:sound, position, "minecraft:entity.turtle.egg_crack", 0.7, pitch()},
          {:set, position, Blocks.state("turtle_egg", Map.put(props, "hatch", "#{hatch + 1}"))}
        ]
      else
        [
          {:sound, position, "minecraft:entity.turtle.egg_hatch", 0.7, pitch()},
          {:set, position, Valimc.Data.BlockFacts.fluid_remains(state)}
        ] ++
          Enum.flat_map(0..(eggs - 1), fn i ->
            [
              {:level_event, position, 2001, state},
              {:mob, "minecraft:turtle", {x + 0.3 + i * 0.2, y * 1.0, z + 0.3},
               %{data: %{age: -24_000, home: position}, reason: :breeding}}
            ]
          end)
      end
    else
      []
    end
  end

  defp pitch,
    do:
      Float32.round(
        Float32.round(0.9) +
          Float32.round(Float32.round(:rand.uniform_real()) * Float32.round(0.2))
      )

  defp sand?(nil), do: false
  defp sand?(state), do: MapSet.member?(@sand, Blocks.block_id(state))

  @doc """
  `destroyEgg`/`decreaseEggs` of eggs at `state` an entity crushed: one
  chance in `randomness` (100 stepping on them, 3 falling on them) one egg
  breaks (the last takes the block). The block's next state and the
  break's sound and event, or nil.
  """
  def crush(state, randomness) do
    if :rand.uniform(randomness) == 1 do
      props = Map.new(Blocks.properties(state))
      eggs = String.to_integer(props["eggs"])

      next =
        if eggs <= 1,
          do: Valimc.Data.BlockFacts.fluid_remains(state),
          else: Blocks.state("turtle_egg", Map.put(props, "eggs", "#{eggs - 1}"))

      {next, pitch()}
    end
  end
end
