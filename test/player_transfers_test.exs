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

  test "creative creation retains every owned stack without weakening ordinary conservation" do
    inv = %Inventory{
      infinite_materials: true,
      selected: 2,
      slots: %{1 => stack(2), 38 => stack(7), 45 => ItemStack.new("egg", 3)},
      carried: stack(4)
    }

    snapshot =
      Map.merge(capture(inv), %{
        game_mode: Valimc.GameMode.new(:creative),
        flying: false,
        fall_distance: 1.0,
        frozen_ticks: 17,
        velocity: {0.2, -0.7, 0.3},
        health: %{value: 7.25, hurt_ticks: 7, death_ticks: 0}
      })

    created = record(2, stack(3))

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(<<1::128>>, 8, snapshot, snapshot, {0, 0}, [created])

    assert {:ok, next} =
             PlayerTransfers.prepare_creative_drop(<<1::128>>, 8, snapshot, {0, 0}, created)

    assert next.inventory == inv and next.pose == snapshot.pose
    assert next.velocity == snapshot.velocity
    assert next.health == snapshot.health
    assert next.transfer_sequence == 9 and next.outbox.records == [created]
    assert {:ok, bytes} = PlayerSnapshot.encode(<<1::128>>, next)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, <<1::128>>)
    assert restored.outbox == next.outbox and restored.inventory.slots == inv.slots
    assert restored.inventory.carried == inv.carried and restored.inventory.selected == 2
    assert restored.velocity == snapshot.velocity
    assert restored.health == snapshot.health
    refute restored.inventory.infinite_materials
  end

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

  test "cursor and crafting-grid overflow plans conserve all physically owned items" do
    full = Map.new(9..44, &{&1, ItemStack.new("stone", 64)})

    inv = %Inventory{
      slots: Map.merge(full, %{1 => stack(7), 2 => ItemStack.new("egg", 3)}),
      carried: ItemStack.new("iron_sword")
    }

    assert {:ok, returned, drops} = Inventory.close(inv)
    assert length(drops) == 3
    records = Enum.with_index(drops, 1) |> Enum.map(fn {item, n} -> record(n, item) end)

    assert {:ok, _} =
             PlayerTransfers.prepare(
               <<1::128>>,
               16,
               capture(inv),
               capture(returned),
               {0, 0},
               records
             )

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(
               <<1::128>>,
               16,
               capture(inv),
               capture(returned),
               {0, 0},
               Enum.drop(records, 1)
             )
  end

  test "large retained stacks plus split-out records respect independent bounded encodings" do
    big = %{
      ItemStack.new("stone", 2)
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"big" => {:byte_array, :binary.copy(<<1>>, 60_000)}}}
        }
    }

    inv = %Inventory{slots: Map.new(9..16, &{&1, big})}
    kept = %{inv | slots: Enum.reduce(9..13, inv.slots, &Map.put(&2, &1, %{big | count: 1}))}
    records = for n <- 1..5, do: record(n, %{big | count: 1})

    assert {:ok, next} =
             PlayerTransfers.prepare(<<1::128>>, 0, capture(inv), capture(kept), {0, 0}, records)

    assert {:ok, bytes} = PlayerSnapshot.encode(<<1::128>>, next)
    assert byte_size(bytes) > 750_000 and byte_size(bytes) <= PlayerSnapshot.max_bytes()
    assert {:ok, ^next} = PlayerSnapshot.decode(bytes, <<1::128>>)
    bad = capture(%{inv | slots: Map.put(inv.slots, 17, big)})

    assert {:error, :inventory_byte_limit} =
             PlayerTransfers.prepare(<<1::128>>, 0, bad, capture(kept), {0, 0}, records)
  end
end
