defmodule Valimc.PlayerAbilitiesTest do
  use ExUnit.Case, async: true
  alias Valimc.Player.Abilities
  import Bitwise

  test "all client flags affect only permission-gated flight; malformed bodies reject" do
    for mode <- [:survival, :creative, :adventure, :spectator], flags <- 0..255 do
      original = Abilities.for_mode(mode)
      assert {:ok, result} = Abilities.request_flight(original, <<flags>>)
      assert result.flying == ((flags &&& 2) != 0 and original.may_fly)
      assert %{result | flying: original.flying} == original
    end

    for body <- [<<>>, <<2, 0>>, <<2, 0.05::float-32, 0.1::float-32>>] do
      assert {:error, :invalid_abilities_packet} =
               Abilities.request_flight(Abilities.for_mode(:creative), body)
    end
  end
end
