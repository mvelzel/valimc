defmodule Valimc.PufferResizeTest do
  use ExUnit.Case, async: true
  alias Valimc.AI.{Facts, Mind, Self, World}
  alias Valimc.Entity.Body

  test "unknown collision cells refuse displacement while preserving the new puff state" do
    {:ok, body} = Body.new("minecraft:pufferfish")
    {width, height, eye} = Body.dimensions(body)

    self = %Self{
      type: body.type,
      uuid: <<1::128>>,
      x: 0.8,
      y: 64.0,
      z: 0.5,
      width: width,
      height: height,
      eye: eye,
      mob: body.mob,
      data: body.data,
      facts: Facts.mob(body.type),
      mind: %Mind{random: Valimc.AI.Random.new(7), own: %{inflate: 1, deflate: 0}},
      world: %World{read: fn _ -> nil end}
    }

    changed = Valimc.AI.Mobs.Pufferfish.tick_start(self)
    assert changed.data.puff == 1
    assert {changed.x, changed.y, changed.z} == {self.x, self.y, self.z}
    assert changed.width > self.width and changed.height > self.height

    assert Valimc.AI.Shapes.free_position(
             self.world,
             {0.0, 0.0, 0.0, 1.0, 1.0, 1.0},
             {0.5, 0.5, 0.5},
             {0.7, 0.7, 0.7},
             Valimc.Physics.CollisionContext.entity(0.0)
           ) == nil
  end
end
