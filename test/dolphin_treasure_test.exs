defmodule Valimc.DolphinTreasureTest do
  use ExUnit.Case, async: true
  alias Valimc.AI.{Facts, Mind, Random, Self, World}
  alias Valimc.AI.Mobs.Dolphin.Treasure
  alias Valimc.Entity.Body

  defp dolphin do
    {:ok, body} = Body.new("minecraft:dolphin")
    {width, height, eye} = Body.dimensions(body)

    %Self{
      id: 1,
      uuid: <<1::128>>,
      type: body.type,
      x: 0.5,
      y: 60.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      head: 0.0,
      on_ground: false,
      velocity: {0.0, 0.0, 0.0},
      width: width,
      height: height,
      eye: eye,
      facts: Facts.mob(body.type),
      mob: body.mob,
      data: %{body.data | got_fish: true},
      mind: %Mind{random: Random.new(7)},
      world: %World{
        random: Random.new(7),
        read: fn _ -> Valimc.Data.Blocks.default_state("water") end
      }
    }
  end

  test "a deferred lookup keeps waiting without a queue; only its own result is consumed" do
    {state, self} = Treasure.start(%{}, dolphin())

    assert [
             {:locate, uuid, token,
              %{tag: "minecraft:dolphin_located", radius: 50, position: {0, 60, 0}}}
           ] = self.effects

    assert uuid == self.uuid and token == state.request
    assert {true, _, _} = Treasure.can_continue(state, self)

    self = %{
      self
      | effects: [],
        world: %{self.world | located: %{{uuid, make_ref()} => {:ok, {18, 60, 12}}}}
    }

    {same, self} = Treasure.tick(state, self)
    assert same.waiting and self.data.treasure == nil
    assert length(self.effects) == 1

    self = %{
      self
      | effects: [],
        world: %{self.world | located: %{{uuid, token} => {:ok, {18, 60, 12}}}}
    }

    {found, self} = Treasure.tick(state, self)
    refute found.waiting
    assert self.data.treasure == {18, 60, 12}
    assert {:event, 38} in self.effects
    assert self.world.located == %{}
  end

  test "low air keeps the fish for a retry; arrival and a missing structure clear it" do
    self = dolphin()
    state = %{stuck: false, waiting: false, request: nil}

    self = %{
      self
      | data: %{self.data | treasure: {18, 60, 12}},
        mob: %{self.mob | living: %{self.mob.living | air_supply: 99}}
    }

    assert {false, _, _} = Treasure.can_continue(state, self)
    {_, stopped} = Treasure.stop(state, self)
    assert stopped.data.got_fish
    {_, arrived} = Treasure.stop(state, %{self | x: 18.5, z: 12.5})
    refute arrived.data.got_fish

    self = dolphin()
    self = %{self | world: %{self.world | locate: fn _ -> {:ok, nil} end}}
    {missing, self} = Treasure.start(%{}, self)
    assert missing.stuck
    {_, stopped} = Treasure.stop(missing, self)
    refute stopped.data.got_fish
  end
end
