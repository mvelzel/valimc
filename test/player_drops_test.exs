defmodule Valimc.PlayerDropsTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Player.Drops
  alias Valimc.Protocol.ItemStack

  defp player(pose \\ :standing),
    do: %{x: 7.5, y: 64.0, z: 3.5, yaw: 0.0, pitch: 0.0, pose: pose}

  test "accepted posture controls launch origin with exact stacks and native motion" do
    stack = %{
      ItemStack.new("stone", 3)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    eye = 1.2699999809265137
    assert {:ok, {0, 0}, [record]} = Drops.records(player(:crouching), [stack], :directed)
    assert record.stack == stack and record.x == 7.5 and record.z == 3.5
    assert record.y == 64.0 + eye - 0.30000001192092896
    assert Drops.at_source?(record, player())
    assert ItemMotionState.valid?(record.motion)
    assert record.motion.pickup_delay == 40 and not record.motion.no_gravity
    {x, y, z} = record.motion.velocity
    assert abs(x) <= 0.02 and y >= 0 and y <= 0.2 and z >= 0.28 and z <= 0.32
  end

  test "death uses scattered upward launches while thrown stacks use directed motion" do
    stone = ItemStack.new("stone", 3)
    assert {:ok, {0, 0}, [record]} = Drops.records(player(), [stone], :scattered)
    assert record.stack == stone and elem(record.motion.velocity, 1) == 0.20000000298023224
    assert {:ok, {0, 0}, [record]} = Drops.records(player(), [stone], :directed)
    assert elem(record.motion.velocity, 2) >= 0.28 and record.motion.pickup_delay == 40
  end

  test "invalid origins, stacks and kinds refuse" do
    stone = ItemStack.new("stone")

    for {pose, stacks, kind} <- [
          {%{player() | y: 1_000_001}, [stone], :directed},
          {%{player() | pose: :unknown}, [stone], :directed},
          {player(), [nil], :directed},
          {player(), [stone], :invalid}
        ],
        do: assert({:error, :invalid_player_drop} = Drops.records(pose, stacks, kind))

    assert {:ok, {0, 0}, []} = Drops.records(player(), [], :directed)
    assert {:ok, _, [record]} = Drops.records(%{player() | x: 0, z: 0}, [stone], :directed)
    assert Drops.at_source?(record, %{player() | x: 0, z: 0})
    refute Drops.at_source?(%{record | x: 1.0}, %{player() | x: 0, z: 0})
  end
end
