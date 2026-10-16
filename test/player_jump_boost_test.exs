defmodule Valimc.PlayerJumpBoostTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerEffects, PlayerJumpBoost}
  alias Valimc.Protocol.EffectTypes
  @id EffectTypes.id("jump_boost")

  test "only the active head changes jump power and safe distance through hidden promotion" do
    effects = %{@id => [{1, 1, false, true, true}, {300, 0, false, true, true}]}
    assert {:ok, strong} = PlayerJumpBoost.derive(effects)
    assert strong.attribute == {29, 3.0, [{"minecraft:effect.jump_boost", 2.0, 0}]}
    assert strong.safe_distance == 5.0 and strong.bonus == 0.20000000298023224
    assert {:ok, weak, _} = PlayerEffects.tick(effects)
    assert PlayerJumpBoost.level(weak) == 0
    assert {:ok, weak} = PlayerJumpBoost.derive(weak)
    assert weak.safe_distance == 4.0 and weak.bonus == 0.10000000149011612
    assert {:ok, empty} = PlayerJumpBoost.derive(%{})
    assert empty.attribute == {29, 3.0, []} and empty.safe_distance == 3.0
  end

  test "material multiplies base strength before adding the native float bonus" do
    assert {:ok, 0.41999998688697815} = PlayerJumpBoost.power(1, -1)
    assert {:ok, 0.5199999809265137} = PlayerJumpBoost.power(1, 0)
    assert {:ok, 0.10000000149011612} = PlayerJumpBoost.power(0, 0)
    assert {:ok, 0.3100000023841858} = PlayerJumpBoost.power(0.5, 0)
    assert {:ok, 27.280000686645508} = PlayerJumpBoost.power(4, 255)
  end

  test "invalid effects and powers cannot enter a geometry request" do
    assert {:error, :invalid_jump_boost} = PlayerJumpBoost.derive(%{@id => []})
    assert {:error, :invalid_jump_boost} = PlayerJumpBoost.derive(nil)

    for {factor, amp} <- [{-1, 0}, {5, 0}, {1, -2}, {1, 256}, {1, 1.5}, {nil, 0}] do
      assert {:error, :invalid_jump_boost} = PlayerJumpBoost.power(factor, amp)
    end
  end
end
