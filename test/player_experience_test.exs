defmodule Valimc.PlayerExperienceTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerExperience, PlayerProgression, PlayerSnapshot}

  test "bounded recipe set and XP wrap existing snapshots without changing legacy bytes" do
    snapshot = %{pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}, inventory: %Inventory{}}
    uuid = <<31::128>>
    {:ok, legacy} = PlayerSnapshot.encode(uuid, snapshot)
    {:ok, xp} = PlayerExperience.give(%PlayerExperience{}, 17)

    {:ok, progression} =
      PlayerProgression.learn(
        %PlayerProgression{experience: xp},
        PlayerProgression.recipe_names()
      )

    {:ok, bytes} = PlayerSnapshot.encode(uuid, Map.put(snapshot, :progression, progression))
    assert <<"VMCPOSE", 21, _::binary>> = bytes
    assert byte_size(bytes) == byte_size(legacy) + 27
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid)
    assert restored.progression == progression
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid, restored)
    assert {:ok, ^legacy} = PlayerSnapshot.encode(uuid, Map.delete(restored, :progression))
    assert {:error, _} = PlayerProgression.learn(progression, ["minecraft:not_a_recipe"])
    {:ok, encoded} = PlayerProgression.encode(progression)
    <<xp_bytes::binary-size(12), _::binary>> = encoded
    assert {:error, _} = PlayerProgression.decode(<<xp_bytes::binary, 1::1, 0::111>>)
    assert {:error, _} = PlayerSnapshot.decode(bytes <> <<0>>, uuid)
  end
end
