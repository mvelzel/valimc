defmodule Valimc.PlayerEffectsTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerEffects, StatusEffect}

  test "expired suppressed promotion carries its update value even when removed in the same tick" do
    ended = {0, 0, false, true, true}
    effects = %{11 => [{1, 2, false, true, true}, ended]}
    assert {:ok, %{}, [{:update, 11, ^ended, true}, {:remove, 11}]} = PlayerEffects.tick(effects)
  end

  test "only bounded catalog IDs and canonical suppression chains enter the map" do
    full_chain = Enum.map(255..0//-1, &{-1, &1, false, true, true})
    full = Map.new(0..39, &{&1, full_chain})
    assert PlayerEffects.valid?(full)
    assert {:ok, ^full, []} = PlayerEffects.tick(full)
    {:ok, incoming} = StatusEffect.new(10, 0)

    for invalid <- [
          nil,
          [],
          Map.put(full, 40, incoming),
          %{11 => []},
          %{11 => full_chain ++ full_chain}
        ] do
      refute PlayerEffects.valid?(invalid)
      assert PlayerEffects.add(invalid, 11, incoming) == {:error, :invalid_player_effects}
      assert PlayerEffects.tick(invalid) == {:error, :invalid_player_effects}
    end

    assert PlayerEffects.add(%{}, 40, incoming) == {:error, :invalid_player_effects}
    assert PlayerEffects.add(%{}, 11, full_chain) == {:error, :invalid_player_effects}
    assert PlayerEffects.remove(%{}, -1) == {:error, :invalid_player_effects}
  end
end
