defmodule Valimc.PlayerEffectsTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerEffects, StatusEffect}

  test "suppressed changes persist and promotion can coincide with the duration refresh" do
    {:ok, strong} = StatusEffect.new(1, 1)
    {:ok, weak} = StatusEffect.new(601, 0)
    assert {:ok, effects, true} = PlayerEffects.add(%{}, 11, strong)
    assert {:ok, effects, false} = PlayerEffects.add(effects, 11, weak)
    assert length(effects[11]) == 2
    {:ok, ended} = StatusEffect.new(0, 0)
    {:ok, effects, true} = PlayerEffects.add(effects, 12, ended)

    assert {:ok, %{11 => [{600, 0, false, true, true}]} = effects,
            [{:update, 11, true}, {:update, 11, false}, {:remove, 12, false}]} =
             PlayerEffects.tick(effects)

    assert {:ok, %{}, true} = PlayerEffects.remove(effects, 11)
    assert {:ok, %{}, false} = PlayerEffects.remove(%{}, 11)
    {:ok, infinite} = StatusEffect.new(-1, 0)
    assert {:ok, %{11 => ^infinite}, []} = PlayerEffects.tick(%{11 => infinite})
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
