defmodule Valimc.AIMoveSinkTest do
  @moduledoc """
  `MoveToTargetSink` with a walk target whose entity left the world: it
  neither starts nor repaths toward it (the first M3 client run 2 crash, a
  Nether owner restarting on a piglin's or hoglin's vanished walk target).
  """
  use ExUnit.Case, async: true
  alias Valimc.AI.{Behaviors, Brain, Navigation, Self, World}

  setup do
    uuid = <<31::128>>
    air = Valimc.Data.Blocks.default_state("air")

    self = %Self{
      uuid: uuid,
      type: "minecraft:piglin",
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      head: 0.0,
      on_ground: true,
      mind: Valimc.AI.mind("minecraft:piglin", uuid, nil),
      width: 0.6,
      height: 1.95,
      eye: 1.79,
      world: %World{read: fn _ -> air end}
    }

    gone = %{target: {:entity, {:mob, <<32::128>>}, false}, speed: 0.5, close: 1}
    %{self: Brain.set(self, :walk_target, gone), sink: Behaviors.move_sink()}
  end

  test "a vanished target does not start the sink and is forgotten", %{self: self, sink: sink} do
    {started, _sink, self} = sink.kind.try_start(sink, self)
    refute started
    assert Brain.get(self, :walk_target) == nil
  end

  test "a running sink whose target vanishes keeps its path", %{self: self, sink: sink} do
    path = %{nodes: [{3, 64, 0}], index: 0}
    self = put_in(self.mind.navigation, %Navigation{path: path})
    state = %{sink.state | path: path, last: {3, 64, 0}}
    assert {%{last: {3, 64, 0}}, _self} = Behaviors.MoveSink.tick(state, self)
  end
end
