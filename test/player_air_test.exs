defmodule Valimc.PlayerAirTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerAir
  alias Valimc.Physics.{BlockCollisions.Frame, PlayerPose}

  test "default submersion has a grace period, bounded repeated damage, and independent surfacing recovery" do
    assert PlayerAir.tick(1, true, false, 0, 0.5) == {0, 0.0}
    assert PlayerAir.tick(-18, true, false, 0, 0.5) == {-19, 0.0}
    assert PlayerAir.tick(-19, true, false, 0, 0.5) == {0, 2.0}
    assert PlayerAir.tick(0, true, false, 0, 0.5) == {-1, 0.0}
    assert PlayerAir.tick(-19, true, true, 0, 0.5) == {-15, 0.0}
    assert PlayerAir.tick(-19, false, false, 0, 0.5) == {-15, 0.0}
    assert PlayerAir.tick(299, false, true, 0, 0.5) == {300, 0.0}
  end

  test "only selected-pose water eyes drain air; both bubble-column states replenish it" do
    frame = %Frame{
      states: %{{0, 64, 0} => 89, {0, 65, 0} => 0, {0, 66, 0} => 0},
      fences: %{},
      entities: %{}
    }

    {:ok, standing} = PlayerPose.geometry(:standing, {0.5, 64.0, 0.5})
    {:ok, swimming} = PlayerPose.geometry(:swimming, {0.5, 64.0, 0.5})
    assert {:ok, %{water: false, submerged: false}} = PlayerAir.contact(frame, standing)
    assert {:ok, %{water: true, submerged: true}} = PlayerAir.contact(frame, swimming)
    full = %{frame | states: Map.put(frame.states, {0, 65, 0}, 89)}
    assert {:ok, %{water: true, submerged: true}} = PlayerAir.contact(full, standing)

    for id <- PlayerAir.bubble_states() do
      assert {:ok, %{water: true, submerged: false}} =
               PlayerAir.contact(
                 %{full | states: Map.put(full.states, {0, 65, 0}, id)},
                 standing
               )
    end

    assert {:error, _} =
             PlayerAir.contact(
               %{frame | states: Map.delete(frame.states, {0, 65, 0})},
               standing
             )
  end

  test "zero air has a twenty-tick grace; surfacing restores four and caps at native maximum" do
    assert PlayerAir.decrease(1, 0, 0.99) == 0
    assert PlayerAir.decrease(0, 0, 0.99) == -1
    refute PlayerAir.drowning?(-19)
    assert PlayerAir.drowning?(PlayerAir.decrease(-19, 0, 0.99))
    assert PlayerAir.increase(-19) == -15
    assert PlayerAir.increase(299) == PlayerAir.maximum()
    assert PlayerAir.valid?(-20) and PlayerAir.valid?(300)
    refute PlayerAir.valid?(-21)
    refute PlayerAir.valid?(301)
  end
end
