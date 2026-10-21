defmodule Valimc.PlayerContainerTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    GameMode,
    Inventory,
    PlayerContainerIntent,
    PlayerContainerTransfers,
    PlayerFood,
    PlayerSnapshot
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, ContainerTransfers}
  @uuid <<81::128>>

  defp fixture(mode \\ :survival) do
    inventory = %Inventory{
      state_id: 17,
      selected: 3,
      carried: ItemStack.new("diamond", 3),
      slots: %{5 => ItemStack.new("iron_helmet"), 36 => ItemStack.new("stone", 2)}
    }

    snapshot = %{
      pose: %{x: 8.5, y: 64.0, z: 8.5, yaw: 0.0, pitch: 0.0},
      inventory: inventory,
      game_mode: GameMode.new(mode),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 19.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      fire_ticks: -20,
      effects: %{},
      absorption: 0.0,
      transfer_sequence: 9,
      outbox: nil
    }

    {:ok, containers, entry} = Containers.create(%Containers{}, {0, 0}, {1, 64, 1}, 3)
    {:ok, containers, _} = ContainerTransfers.reserve(containers, @uuid)

    request = %{
      source: @uuid,
      sequence: 10,
      permit: <<82::128>>,
      position: {1, 64, 1},
      revision: entry.revision,
      rows: 3,
      slots: entry.slots,
      inventory: inventory,
      action: :pickup,
      slot: 0,
      button: 0
    }

    {snapshot, %{kind: :container, key: {0, 0}, request: request}, containers}
  end

  test "original items persist before receipt-backed sealing" do
    {snapshot, intent, containers} = fixture(:creative)
    assert {:ok, pending} = PlayerContainerTransfers.prepare(@uuid, 9, snapshot, intent)
    assert pending.inventory == snapshot.inventory and pending.transfer_sequence == 10
    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored.inventory.carried == snapshot.inventory.carried
    assert restored.inventory.slots == snapshot.inventory.slots
    assert restored.effects == %{} and restored.absorption == 0.0 and restored.fire_ticks == -20
    assert {:ok, key, request, _} = PlayerContainerIntent.request(@uuid, 10, restored.outbox)
    assert request.inventory.infinite_materials == true

    assert {:ok, %{result: :applied, containers: committed}} =
             ContainerTransfers.plan(containers, key, request, true)

    assert {:ok, sealed} =
             PlayerContainerTransfers.resolve(@uuid, restored, committed.receipts[@uuid])

    assert sealed.inventory.carried == nil and
             sealed.inventory.slots == snapshot.inventory.slots

    assert sealed.health == snapshot.health and sealed.food == snapshot.food
    assert sealed.inventory.infinite_materials == true
    assert sealed.outbox == nil and sealed.transfer_sequence == 10
    assert {:ok, sealed_bytes} = PlayerSnapshot.encode(@uuid, sealed)

    assert {:ok, %{outbox: nil, transfer_sequence: 10}} =
             PlayerSnapshot.decode(sealed_bytes, @uuid)

    assert {:error, :invalid_container_plan} =
             PlayerContainerTransfers.resolve(@uuid, sealed, committed.receipts[@uuid])
  end

  test "rejection keeps original items and accepted permission survives a later mode change" do
    {snapshot, intent, containers} = fixture()
    {:ok, pending} = PlayerContainerTransfers.prepare(@uuid, 9, snapshot, intent)

    {:ok, %{containers: rejected}} =
      ContainerTransfers.plan(containers, intent.key, pending.outbox.request, false)

    assert {:ok, sealed} =
             PlayerContainerTransfers.resolve(@uuid, pending, rejected.receipts[@uuid])

    assert sealed.inventory == snapshot.inventory and sealed.transfer_sequence == 10 and
             sealed.outbox == nil

    {:ok, %{containers: applied}} =
      ContainerTransfers.plan(containers, intent.key, pending.outbox.request, true)

    switched = %{pending | game_mode: GameMode.new(:creative)}

    assert {:ok, sealed} =
             PlayerContainerTransfers.resolve(@uuid, switched, applied.receipts[@uuid])

    assert sealed.inventory.carried == nil and sealed.inventory.infinite_materials
  end

  test "v20 inner journal works with each independent effect/fire/absorption wrapper" do
    {snapshot, intent, _} = fixture()

    for keys <- [
          [],
          [:fire_ticks],
          [:effects],
          [:absorption],
          [:fire_ticks, :effects, :absorption]
        ] do
      base = Map.drop(snapshot, [:fire_ticks, :effects, :absorption] -- keys)
      assert {:ok, pending} = PlayerContainerTransfers.prepare(@uuid, 9, base, intent)
      assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
      assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)

      assert restored.outbox.kind == :container and
               restored.inventory.carried == snapshot.inventory.carried

      assert restored.transfer_sequence == 10
      if keys == [], do: assert(<<"VMCPOSE", 20, _::binary>> = bytes)
    end
  end

  test "a pending or exhausted source cannot prepare another intent" do
    {snapshot, intent, _} = fixture()

    assert {:error, :invalid_container_plan} =
             PlayerContainerTransfers.prepare(@uuid, 8, snapshot, intent)

    {:ok, pending} = PlayerContainerTransfers.prepare(@uuid, 9, snapshot, intent)

    assert {:error, :invalid_container_plan} =
             PlayerContainerTransfers.prepare(@uuid, 10, pending, intent)

    assert {:error, :invalid_container_plan} =
             PlayerContainerTransfers.prepare(@uuid, 18_446_744_073_709_551_615, snapshot, intent)
  end
end
