defmodule Valimc.ChestOpeningTest do
  use ExUnit.Case, async: true
  # They check the 250 ms window's edge (VMC-073).
  setup do: Valimc.TestScope.isolate(self(), owner_call_scale: 1)
  alias Valimc.ChestOpening
  alias Valimc.Protocol.Data
  @block hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  test "initial hand/lid admission differs from an existing menu's range and revision check" do
    entry = %{revision: 7, rows: 3, slots: Tuple.duplicate(nil, 27)}
    position = {0, 64, 0}

    grant = %{
      kind: :open,
      mode: :survival,
      eye: {0.5, 65.5, 0.5},
      expires: 1100,
      hand: :main,
      secondary: false,
      main: false,
      off: true
    }

    air = Data.block("air")

    assert {:chest, @block, ^entry} =
             ChestOpening.authorize(@block, entry, air, position, grant, 1000)

    assert :pass =
             ChestOpening.authorize(
               @block,
               entry,
               air,
               position,
               %{grant | secondary: true},
               1000
             )

    assert {:error, :blocked_chest} =
             ChestOpening.authorize(@block, entry, Data.block("stone"), position, grant, 1000)

    check = Map.merge(grant, %{kind: :check, menu: :chest, revision: 7})

    assert :valid =
             ChestOpening.authorize(@block, entry, Data.block("stone"), position, check, 1000)

    assert {:chest, @block, ^entry} =
             ChestOpening.authorize(@block, entry, air, position, %{check | revision: 6}, 1000)

    assert {:error, :invalid_chest_context} =
             ChestOpening.authorize(@block, entry, air, position, %{check | menu: :table}, 1000)

    assert {:error, :missing_chest} =
             ChestOpening.authorize(@block, nil, air, position, grant, 1000)

    assert {:error, :invalid_chest_context} =
             ChestOpening.authorize(
               @block,
               entry,
               air,
               position,
               %{check | eye: {10.0, 65.5, 0.5}},
               1000
             )

    for expires <- [1000, 1251] do
      assert {:error, :expired_chest_grant} =
               ChestOpening.authorize(
                 @block,
                 entry,
                 air,
                 position,
                 %{grant | expires: expires},
                 1000
               )
    end

    assert {:error, :invalid_chest_grant} =
             ChestOpening.authorize(@block, entry, air, position, %{}, 1000)
  end
end
