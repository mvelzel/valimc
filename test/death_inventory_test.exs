defmodule Valimc.DeathInventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack

  defp cursed,
    do: %{
      ItemStack.new("stone", 3)
      | components: %{"minecraft:enchantments" => %{"minecraft:vanishing_curse" => 0}}
    }

  defp snapshot(inventory),
    do: %{
      pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0},
      inventory: inventory,
      flying: false,
      game_mode: Valimc.GameMode.new(:survival),
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 0.0, hurt_ticks: 0, death_ticks: 0}
    }

  test "only a dead owner can authorize exactly the native destruction and selected batch" do
    before =
      snapshot(%Inventory{
        slots: %{36 => cursed(), 37 => ItemStack.new("stone", 7), 38 => ItemStack.new("egg", 2)}
      })

    assert {:ok, after_snapshot, key, records} = PlayerTransfers.plan_death(before)

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(<<1::128>>, 0, before, after_snapshot, key, records)

    assert {:ok, pending} =
             PlayerTransfers.prepare_death(<<1::128>>, 0, before, after_snapshot, key, records)

    assert pending.health == before.health and pending.transfer_sequence == 1
    assert {:ok, bytes} = PlayerState.encode(<<1::128>>, pending)
    assert {:ok, loaded} = PlayerState.decode(bytes, <<1::128>>)
    assert loaded.health == before.health and loaded.inventory.slots == %{}
    assert Enum.sort_by(loaded.outbox.records, & &1.uuid) == Enum.sort_by(records, & &1.uuid)

    assert {:error, :player_not_dead} =
             PlayerTransfers.prepare_death(
               <<1::128>>,
               0,
               put_in(before.health.value, 20.0),
               after_snapshot,
               key,
               records
             )

    assert {:error, :invalid_death_plan} =
             PlayerTransfers.prepare_death(
               <<1::128>>,
               0,
               before,
               %{after_snapshot | health: %{before.health | value: 20.0}},
               key,
               records
             )

    assert {:error, :invalid_death_plan} =
             PlayerTransfers.prepare_death(
               <<1::128>>,
               0,
               before,
               after_snapshot,
               key,
               Enum.reverse(records)
             )
  end
end
