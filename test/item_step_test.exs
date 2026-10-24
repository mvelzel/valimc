defmodule Valimc.Physics.ItemStepTest do
  use ExUnit.Case, async: true
  alias Valimc.World.View
  alias Valimc.Entity.ItemMotionState
  alias Valimc.World.ItemStep

  defp frame(floor_state \\ 1, layer \\ 0) do
    View.of(
      for x <- -3..5,
          y <- 62..68,
          z <- -3..5,
          into: %{},
          do: {{x, y, z}, if(y == 63, do: floor_state, else: if(y == 64, do: layer, else: 0))}
    )
  end

  defp item(position \\ {0.5, 65.5, 0.5}, motion \\ %ItemMotionState{}),
    do: %{id: 7, position: position, motion: motion}

  test "missing and embedded geometry refuse rather than inventing air" do
    assert [{:error, {:missing_block, _}}] = ItemStep.run(View.of(%{}), [item()], nil)
    assert [{:error, :item_inside_block}] = ItemStep.run(frame(), [item({0.5, 63.5, 0.5})], nil)
  end

  test "a falling item lands on the floor and ages" do
    [{:ok, landed}] = ItemStep.run(frame(), [item({0.5, 64.01, 0.5})], nil)
    assert {0.5, 64.0, 0.5} == landed.position and landed.motion.on_ground
    assert landed.motion.age == 1 and landed.id == 7
  end

  test "lava burns an item up on its second tick unless fire cannot hurt it" do
    lava = frame(1, Valimc.Data.Blocks.default_state("lava"))
    [{:ok, first}] = ItemStep.run(lava, [item({0.5, 64.0, 0.5})], nil)
    assert {first.motion.health, first.motion.fire_ticks, first.dead} == {1, 300, false}
    [{:ok, second}] = ItemStep.run(lava, [first], nil)
    assert second.dead

    immune = item({0.5, 64.0, 0.5}) |> Map.put(:fire_immune, true)
    [{:ok, kept}] = ItemStep.run(lava, [immune], nil)
    assert {kept.motion.health, kept.motion.fire_ticks, kept.dead} == {5, 0, false}
  end

  test "dolphins use an item's fluid observation at the water edge and above its surface" do
    water = Valimc.Data.Blocks.default_state("water")

    states =
      for x <- -3..5,
          y <- 62..68,
          z <- -3..5,
          into: %{},
          do: {{x, y, z}, if(y == 63, do: 1, else: if(y == 64 and x <= 3, do: water, else: 0))}

    view = View.of(states)
    wet = item({4.05, 64.0, 0.5}, %ItemMotionState{no_gravity: true})
    dry = item({0.5, 64.95, 0.5}, %ItemMotionState{no_gravity: true})
    [{:ok, wet}, {:ok, dry}] = ItemStep.run(view, [wet, dry], nil)
    assert wet.motion.in_water
    refute dry.motion.in_water
    assert states[{4, 64, 0}] == 0
    assert states[{0, 64, 0}] == water

    sensed =
      for {step, n} <- [{wet, 1}, {dry, 2}] do
        {x, y, z} = step.position

        %{
          kind: :item,
          uuid: <<n::128>>,
          x: x,
          y: y,
          z: z,
          width: 0.25,
          height: 0.25,
          count: 1,
          pickup_delay: 0,
          in_water: step.motion.in_water
        }
      end

    self = %Valimc.AI.Self{
      x: 0.5,
      y: 64.0,
      z: 0.5,
      width: 0.9,
      height: 0.6,
      world: %Valimc.AI.World{items: sensed, read: fn p -> states[p] end}
    }

    assert [hd(sensed)] == Valimc.AI.Mobs.Dolphin.items(self)
    self = put_in(self.world.items, [%{hd(sensed) | pickup_delay: 1}])
    assert Valimc.AI.Mobs.Dolphin.items(self) == []
  end
end
