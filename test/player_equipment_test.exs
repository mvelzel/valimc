defmodule Valimc.PlayerEquipmentTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerEquipment}
  alias Valimc.Protocol.{Data, ItemStack, Packets}

  test "six player slots use selected hands, clear removed gear, and compare count plus effective components" do
    bread = ItemStack.new("bread", 2)
    helmet = ItemStack.new("iron_helmet")

    inv = %Inventory{
      selected: 1,
      slots: %{
        37 => bread,
        45 => bread,
        5 => helmet,
        9 => ItemStack.new("stone"),
        36 => ItemStack.new("bowl")
      }
    }

    captured = PlayerEquipment.capture(inv)
    assert captured == %{0 => bread, 1 => bread, 5 => helmet}

    patched = %{
      bread
      | components: %{"minecraft:food" => Valimc.FoodItems.properties(bread).food}
    }

    assert PlayerEquipment.changes(Map.put(captured, 0, patched), captured) == []

    assert PlayerEquipment.changes(%{captured | 0 => %{bread | count: 1}}, captured) == [
             {0, %{bread | count: 1}}
           ]

    assert PlayerEquipment.changes(%{}, captured) == [{0, nil}, {1, nil}, {5, nil}]
  end

  test "tracking recreations initialize gear, same-position equipment deltas do not fabricate movement" do
    player = %{
      entity_id: 300,
      uuid: <<0::128>>,
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      equipment: %{0 => ItemStack.new("bread", 2)}
    }

    view = Packets.view(player)
    assert Packets.move_entity(player, view) == []
    updated = %{player | equipment: %{0 => ItemStack.new("bowl")}}
    assert [packet] = Packets.move_entity(updated, view)
    assert elem(packet, 0) == Data.id(:play, :clientbound, "set_equipment")
    packets = Packets.move_entity(%{updated | x: 10.5}, view)
    assert List.last(packets) == hd(Packets.player_equipment(updated))
    assert hd(packets) == Packets.remove_entity(view)
    assert Packets.remove_info(player) == Packets.remove_info(view)
  end
end
