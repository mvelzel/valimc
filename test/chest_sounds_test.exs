defmodule Valimc.Protocol.ChestSoundsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ChestSounds

  test "float32 pitch stays in native range at both RNG boundaries" do
    assert {:ok, minimum} = ChestSounds.pitch(0.0)
    assert <<minimum::float-32>> == <<0.9::float-32>>
    assert {:ok, 1.0} = ChestSounds.pitch(16_777_215 / 16_777_216)

    for draw <- [-0.1, 1.0, nil],
        do: assert(ChestSounds.pitch(draw) == {:error, :invalid_chest_sound})
  end

  test "stock sound packets admit only bounded physical chest coordinates and signed seed bits" do
    for open? <- [false, true],
        seed <- [-9_223_372_036_854_775_808, 0, 9_223_372_036_854_775_807] do
      assert {:ok, {_id, body}} = ChestSounds.packet(open?, {-1, -64, 15}, 0.5, seed)
      assert is_binary(IO.iodata_to_binary(body))
    end

    for {position, seed} <- [
          {{0, 320, 0}, 0},
          {{30_000_000, 64, 0}, 0},
          {{0.5, 64, 0}, 0},
          {{0, 64, 0}, 9_223_372_036_854_775_808}
        ] do
      assert {:error, :invalid_chest_sound} = ChestSounds.packet(true, position, 0.5, seed)
    end
  end

  test "stock audience excludes its exact three-dimensional radius and uses player feet" do
    assert ChestSounds.audible?(%{x: 16.499, y: 64.5, z: 0.5}, {0, 64, 0})
    refute ChestSounds.audible?(%{x: 16.5, y: 64.5, z: 0.5}, {0, 64, 0})
    refute ChestSounds.audible?(%{x: 0.5, y: 80.5, z: 0.5}, {0, 64, 0})
    assert ChestSounds.audible?(%{x: -0.5, y: -64.0, z: -0.5}, {-1, -64, -1})
  end
end
