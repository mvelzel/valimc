defmodule Valimc.StatusEffectPacketsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{EffectTypes, Packets}

  test "effect holder identities remain finite and unknown holders cannot be encoded" do
    assert EffectTypes.id("fire_resistance") == EffectTypes.id("minecraft:fire_resistance")
    assert EffectTypes.name(11) == "minecraft:fire_resistance"
    assert_raise KeyError, fn -> EffectTypes.id("unknown_effect") end

    for id <- [-1, EffectTypes.count(), nil, 1.0] do
      refute EffectTypes.valid_id?(id)
      assert_raise ArgumentError, fn -> Packets.remove_effect(128, id) end

      assert_raise ArgumentError, fn ->
        Packets.update_effect(128, id, {20, 0, false, true, true}, false)
      end
    end
  end

  test "effect encoders refuse malformed durations, amplifiers, flags and entity IDs" do
    for rung <- [
          {-2, 0, false, true, true},
          {2_147_483_648, 0, false, true, true},
          {1, 256, false, true, true},
          {1, -1, false, true, true},
          {1, 0, nil, true, true},
          {1, 0, false, 1, true}
        ] do
      assert_raise ArgumentError, fn -> Packets.update_effect(128, 11, rung, true) end
    end

    assert_raise ArgumentError, fn ->
      apply(Packets, :update_effect, [128, 11, {20, 0, false, true, true}, nil])
    end

    for entity <- [-1, 0, 2_147_483_648] do
      assert_raise ArgumentError, fn -> Packets.remove_effect(entity, 11) end
    end
  end
end
