defmodule Valimc.PlayerFireContactsTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerBurning, PlayerFireContacts}

  test "same-step ignition deduplicates while callbacks retain native effect and contact order" do
    assert {:ok,
            [
              :clear_freeze,
              :fire_ignite,
              {:damage, :in_fire, 2.0},
              {:damage, :in_fire, 1.0},
              :lava_ignite,
              :lava_hurt,
              :lava_hurt,
              :extinguish
            ]} = PlayerFireContacts.plan([[:water, :lava, :soul_fire, :lava, :fire]])

    assert {:ok, [:extinguish, :clear_freeze, :fire_ignite, {:damage, :in_fire, 1.0}]} =
             PlayerFireContacts.plan([[:water], [:fire]])
  end

  test "contact work is bounded and unknown or malformed samples refuse" do
    assert {:ok, []} = PlayerFireContacts.plan([])
    assert {:ok, [:extinguish]} = PlayerFireContacts.plan([List.duplicate(:water, 2048)])

    for invalid <- [
          List.duplicate([], 2049),
          [List.duplicate(:fire, 2049)],
          [[:rain]],
          [nil],
          nil
        ] do
      assert {:error, :invalid_fire_contacts} = PlayerFireContacts.plan(invalid)
    end
  end

  test "negative fire cooldowns advance without randomness and positive exposure can extend" do
    no_random = fn -> flunk("negative cooldown or immunity consumed randomness") end
    assert {:ok, %{ticks: -1}} = PlayerBurning.fire(-2, false, 1, false, no_random)
    assert {:ok, %{ticks: 160}} = PlayerBurning.fire(-1, false, 1, false, no_random)
    assert {:ok, %{ticks: 300}} = PlayerBurning.fire(300, true, 1, false, no_random)
    assert {:ok, %{ticks: 302}} = PlayerBurning.fire(300, false, 1, false, fn -> 2 end)
    assert {:ok, %{ticks: 64}} = PlayerBurning.fire(-1, false, 0.3999999761581421)
    assert {:ok, %{ticks: 1}} = PlayerBurning.fire(300, false, 1, true, fn -> 2 end)
  end

  test "signed counter overflow and zero-duration contact follow setter order" do
    assert {:ok, %{ticks: -2_147_483_647, clear_freeze: false}} =
             PlayerBurning.fire(2_147_483_647, false, 1, false, fn -> 2 end)

    assert {:ok, %{ticks: 0, clear_freeze: true}} = PlayerBurning.fire(-1, false, 0)
    assert {:error, :invalid_burning} = PlayerBurning.fire(0, false, 1, false, fn -> 3 end)
    assert {:error, :invalid_burning} = PlayerBurning.fire(-2_147_483_649, false, 1)
  end
end
