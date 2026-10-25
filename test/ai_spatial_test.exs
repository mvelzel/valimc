defmodule Valimc.AISpatialTest do
  use ExUnit.Case, async: true
  alias Valimc.AI.{Self, Spatial, World}

  test "indexed box queries equal linear queries after moves, type/state changes and death" do
    mobs =
      for n <- 1..160 do
        %{
          uuid: <<n::128>>,
          type: if(rem(n, 3) == 0, do: "cow", else: "sheep"),
          x: rem(n, 16) * 8.0 - 64,
          y: rem(n, 2) * 10.0 + 64,
          z: div(n, 16) * 8.0 - 40,
          width: if(n == 1, do: 32.0, else: 0.9),
          height: 1.3,
          alive: true
        }
      end

    world = %World{
      mobs: mobs,
      by_type: Enum.group_by(mobs, & &1.type),
      index: Map.new(mobs, &{&1.uuid, &1}),
      spatial: Spatial.new(mobs)
    }

    Enum.reduce(mobs, world, fn m, world ->
      world = World.resense(world, m.uuid, &%{&1 | x: &1.x + 31.0, z: &1.z - 17.0, alive: false})

      for box <- [World.inflate(World.box(m), 8, 5, 8), {-1000, -1000, -1000, 1000, 1000, 1000}],
          types <- [["cow"], ["cow", "sheep"], [], fn _ -> true end] do
        indexed = World.mobs_in(%Self{world: world}, types, box)
        linear = World.mobs_in(%Self{world: %{world | spatial: nil}}, types, box)
        assert indexed == linear
      end

      world
    end)
  end
end
