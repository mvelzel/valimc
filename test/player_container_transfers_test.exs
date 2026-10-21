defmodule Valimc.PlayerContainerTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{GameMode, Inventory, PlayerContainerTransfers, PlayerFood, PlayerSnapshot}

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
end
