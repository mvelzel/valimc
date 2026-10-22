defmodule Valimc.PlayerEffectSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.Living.Effects
  alias Valimc.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  @uuid <<94::128>>
  @pose %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
  @effects %{11 => [{2, 2, false, true, true}, {-1, 0, true, false, true}]}
  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "bounded canonical effect payload refuses duplicate IDs, chains, flags and truncation" do
    full_chain = Enum.map(255..0//-1, &{-1, &1, false, true, true})
    full = Map.new(0..39, &{&1, full_chain})
    assert {:ok, bytes} = Effects.encode(full)
    assert byte_size(bytes) == Effects.max_bytes()
    assert {:ok, ^full, <<7, 8>>} = Effects.take(bytes <> <<7, 8>>)
    assert {:ok, <<0>>} = Effects.encode(%{})

    for bytes <- [
          <<>>,
          <<41>>,
          <<1, 40, 1::16, 1::signed-32, 0, 6>>,
          <<1, 11, 0::16>>,
          <<1, 11, 257::16>>,
          <<1, 11, 1::16, -2::signed-32, 0, 6>>,
          <<1, 11, 1::16, 1::signed-32, 0, 8>>,
          <<1, 11, 2::16, 1::signed-32, 0, 6, 1::signed-32, 1, 6>>,
          <<2, 11, 1::16, 1::signed-32, 0, 6, 11, 1::16, 1::signed-32, 0, 6>>,
          binary_part(bytes, 0, byte_size(bytes) - 1)
        ] do
      assert Effects.take(bytes) == {:error, :invalid_player_effects}
    end
  end
end
