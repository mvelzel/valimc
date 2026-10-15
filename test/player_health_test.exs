defmodule Valimc.PlayerHealthTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerHealth

  test "health clamps at zero/max, persists native fields and resets transient damage state" do
    assert {:ok, damaged} = PlayerHealth.set(%PlayerHealth{}, 7.25)
    damaged = %{damaged | hurt_ticks: 7, death_ticks: 11, cooldown: 17, last_hurt: 5.0}
    assert {:ok, saved} = PlayerHealth.saved(damaged)
    assert saved == %{value: 7.25, hurt_ticks: 7, death_ticks: 11}
    assert {:ok, restored} = PlayerHealth.restore(saved)
    assert restored == %{damaged | cooldown: 0, last_hurt: 0.0}
    assert {:ok, %{value: 5.0, maximum: 5.0}} = PlayerHealth.restore(saved, 5.0)
    assert {:ok, %{value: 1024.0, maximum: 1024.0}} = PlayerHealth.restore(nil, 1024)
    assert {:ok, %{value: +0.0}} = PlayerHealth.reduce(damaged, 8)
    assert {:ok, %{value: 20.0}} = PlayerHealth.set(damaged, 200)

    for invalid <- [
          nil,
          %{saved | value: -1.0},
          %{saved | value: 1025.0},
          %{saved | value: 0.1},
          %{saved | hurt_ticks: 32768},
          %{saved | death_ticks: -1}
        ] do
      refute PlayerHealth.valid_saved?(invalid)
    end

    for maximum <- [0, 1025, :bad] do
      assert {:error, :invalid_health} = PlayerHealth.restore(saved, maximum)
    end
  end

  test "protected damage takes only a stronger hit's increase before defenses" do
    state = %PlayerHealth{cooldown: 11, hurt_ticks: 4, last_hurt: 5.0}
    assert {:ok, %{accepted: false, state: ^state}} = PlayerHealth.hurt_window(state, 5)
    assert {:ok, stronger} = PlayerHealth.hurt_window(state, 7)
    assert stronger.accepted and stronger.damage == 2.0 and not stronger.notify
    assert stronger.state == %{state | last_hurt: 7.0}
    assert {:ok, fresh} = PlayerHealth.hurt_window(%{state | cooldown: 10}, 3)
    assert fresh.accepted and fresh.notify and fresh.damage == 3.0
    assert fresh.state.cooldown == 20 and fresh.state.hurt_ticks == 10
    assert {:ok, bypass} = PlayerHealth.hurt_window(state, 3, true)
    assert bypass.notify and bypass.damage == 3.0
    assert {:ok, %{accepted: false}} = PlayerHealth.hurt_window(%{state | value: 0.0}, 20, true)
    assert {:ok, %{accepted: true, damage: +0.0}} = PlayerHealth.hurt_window(%PlayerHealth{}, -1)
    assert {:error, :invalid_health} = PlayerHealth.hurt_window(state, 1, :bad)
    assert {:error, :invalid_health} = PlayerHealth.reduce(state, -1)
    assert {:error, :invalid_health} = PlayerHealth.set(%{state | value: 21.0}, 10)
  end

  test "logical ticks saturate hurt/cooldown without mutating health or death lifecycle" do
    state = %PlayerHealth{
      value: 7.25,
      hurt_ticks: 1,
      death_ticks: 11,
      cooldown: 2,
      last_hurt: 5.0
    }

    assert PlayerHealth.tick(state) == %{state | hurt_ticks: 0, cooldown: 1}
    settled = %{state | hurt_ticks: 0, cooldown: 0}
    assert state |> PlayerHealth.tick() |> PlayerHealth.tick() |> PlayerHealth.tick() == settled
  end
end
