defmodule Valimc.PlayerTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.ItemStack
  defp pose, do: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}

  defp stack(count),
    do: %{
      ItemStack.new("stone", count)
      | components: %{
          "minecraft:custom_data" => {:compound, %{"proof" => {:string, "source"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

  defp record(n, item), do: %{uuid: <<n::128>>, x: 0.5, y: 64.5, z: 0.5, stack: item}
  defp capture(inv), do: PlayerSnapshot.capture(pose(), inv)

  test "creative creation requires live permission and exactly one valid bounded nonempty record" do
    snapshot = capture(Inventory.new())
    uuid = <<1::128>>
    created = record(2, stack(3))

    assert {:error, :creative_drop_not_authorized} =
             PlayerTransfers.prepare_creative_drop(uuid, 0, snapshot, {0, 0}, created)

    authorized = %{snapshot | inventory: %{snapshot.inventory | infinite_materials: true}}

    for invalid <- [nil, [], [created], [created, created], %{created | stack: nil}] do
      assert {:error, _} =
               PlayerTransfers.prepare_creative_drop(uuid, 0, authorized, {0, 0}, invalid)
    end

    for invalid <- [
          %{created | uuid: <<0>>},
          %{created | x: 128.5},
          %{created | stack: %{stack(3) | count: 65}},
          %{
            created
            | stack: %{stack(3) | components: %{"minecraft:custom_name" => "unsupported"}}
          }
        ] do
      assert {:error, _} =
               PlayerTransfers.prepare_creative_drop(uuid, 0, authorized, {0, 0}, invalid)
    end

    assert {:error, :transfer_sequence_exhausted} =
             PlayerTransfers.prepare_creative_drop(
               uuid,
               18_446_744_073_709_551_615,
               authorized,
               {0, 0},
               created
             )
  end

  test "source plans conserve component-aware owned stacks and advance the source sequence" do
    before = capture(%Inventory{slots: %{36 => stack(7)}})
    after_state = capture(%Inventory{slots: %{36 => stack(4)}})

    assert {:ok, next} =
             PlayerTransfers.prepare(<<1::128>>, 0, before, after_state, {0, 0}, [
               record(2, stack(3))
             ])

    assert next.transfer_sequence == 1 and next.inventory == after_state.inventory
    assert next.outbox.records == [record(2, stack(3))]

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(<<1::128>>, 0, before, after_state, {0, 0}, [
               record(2, stack(4))
             ])

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(<<1::128>>, 0, before, after_state, {0, 0}, [
               record(2, ItemStack.new("stone", 3))
             ])

    assert {:error, :transfer_sequence_exhausted} =
             PlayerTransfers.prepare(
               <<1::128>>,
               18_446_744_073_709_551_615,
               before,
               after_state,
               {0, 0},
               [record(2, stack(3))]
             )
  end
end
