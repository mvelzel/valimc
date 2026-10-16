defmodule Valimc.TableMenuTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, TableMenu, PlayerCraftingTransfers, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack

  defp table(cells, slots) do
    %Inventory{table_inputs: Enum.map(1..9, &cells[&1]) |> List.to_tuple(), slots: slots}
  end

  defp pickaxe do
    table(
      %{
        1 => ItemStack.new("oak_planks", 2),
        2 => ItemStack.new("spruce_planks", 2),
        3 => ItemStack.new("birch_planks", 2),
        5 => ItemStack.new("stick", 2),
        8 => ItemStack.new("stick", 2)
      },
      %{
        1 => ItemStack.new("diamond", 7),
        5 => ItemStack.new("iron_helmet"),
        45 => ItemStack.new("shield")
      }
    )
  end

  defp powder do
    cells =
      Map.new(1..4, &{&1, ItemStack.new("sand", 2)})
      |> Map.merge(Map.new(5..8, &{&1, ItemStack.new("gravel", 2)}))
      |> Map.put(9, ItemStack.new("white_dye", 2))

    full =
      Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})
      |> Map.put(44, ItemStack.new("white_concrete_powder", 62))

    table(cells, full)
  end

  test "logical slots map to table inputs and storage while physical hands/equipment stay stable" do
    inv = pickaxe()

    assert TableMenu.address(1) == {:ok, {:table, 0}} and
             TableMenu.address(9) == {:ok, {:table, 8}}

    assert TableMenu.address(10) == {:ok, 9} and TableMenu.address(45) == {:ok, 44}

    for slot <- [-2, 46, 99],
        do: assert(TableMenu.plan_click(inv, :pickup, slot, 0) == {:error, :invalid_table_slot})

    assert TableMenu.plan_click(Inventory.new(), :pickup, 1, 0) == {:error, :table_not_open}
    assert length(TableMenu.contents(inv)) == 46
    assert Enum.at(TableMenu.contents(inv), 5) == ItemStack.new("stick", 2)

    assert Inventory.get(inv, 5) == ItemStack.new("iron_helmet") and
             Inventory.held(inv, :off) == ItemStack.new("shield")

    assert hd(TableMenu.contents(inv)) == ItemStack.new("wooden_pickaxe")
    {:ok, next, []} = TableMenu.plan_click(inv, :pickup, 0, 1)
    assert next.carried == ItemStack.new("wooden_pickaxe")
    assert Enum.all?(Inventory.table_contents(next) |> Enum.reject(&is_nil/1), &(&1.count == 1))
    assert next.slots == inv.slots and Inventory.get(next, 0) == nil
    assert {:ok, unchanged, []} = TableMenu.plan_click(next, :pickup, 0, 0)
    assert unchanged.table_inputs == next.table_inputs and unchanged.carried == next.carried
  end

  test "input shifts and number swaps use physical hotbar/offhand; storage shifts never equip" do
    inv =
      table(%{9 => ItemStack.new("iron_helmet")}, %{
        36 => ItemStack.new("oak_log", 2),
        45 => ItemStack.new("shield")
      })

    {:ok, next, []} = TableMenu.plan_click(inv, :swap, 8, 0)

    assert Inventory.get(next, {:table, 7}) == ItemStack.new("oak_log", 2) and
             Inventory.get(next, 36) == nil

    {:ok, next, []} = TableMenu.plan_click(next, :swap, 7, 40)

    assert Inventory.get(next, {:table, 6}) == ItemStack.new("shield") and
             Inventory.held(next, :off) == nil

    {:ok, next, []} = TableMenu.plan_click(next, :quick_move, 9, 0)

    assert Inventory.get(next, 9) == ItemStack.new("iron_helmet") and
             Inventory.get(next, 5) == nil

    {:ok, next, []} = TableMenu.plan_click(next, :quick_move, 10, 0)

    assert Inventory.get(next, {:table, 0}) == ItemStack.new("iron_helmet") and
             Inventory.get(next, 5) == nil

    assert Inventory.get(next, {:table, 6}) == ItemStack.new("shield")

    full_grid =
      table(Map.new(1..9, &{&1, ItemStack.new("bedrock", 64)}), %{
        9 => ItemStack.new("iron_helmet")
      })

    {:ok, next, []} = TableMenu.plan_click(full_grid, :quick_move, 10, 0)

    assert Inventory.get(next, 36) == ItemStack.new("iron_helmet") and
             Inventory.get(next, 5) == nil
  end

  test "table collection excludes player grid, armor and offhand in both directions" do
    inv =
      table(%{1 => ItemStack.new("oak_planks", 63), 9 => ItemStack.new("oak_planks", 2)}, %{
        1 => ItemStack.new("oak_planks", 11),
        9 => ItemStack.new("oak_planks", 4),
        44 => ItemStack.new("oak_planks", 8),
        45 => ItemStack.new("oak_planks", 13)
      })

    inv = %{inv | carried: ItemStack.new("oak_planks", 2)}

    for button <- [0, 1] do
      {:ok, next, []} = TableMenu.plan_click(inv, :pickup_all, 5, button)
      assert next.carried == ItemStack.new("oak_planks", 64)
      assert Inventory.get(next, 1) == inv.slots[1] and Inventory.get(next, 45) == inv.slots[45]
      assert Inventory.get(next, {:table, 0}).count == if(button == 0, do: 1, else: 15)
    end
  end

  test "nine-input result overflow is authorized as an exact durable recipe conversion" do
    inv = powder()
    assert Inventory.crafting_result(inv) == ItemStack.new("white_concrete_powder", 8)
    assert {:ok, next, [drop]} = TableMenu.plan_click(inv, :quick_move, 0, 0)
    assert drop == ItemStack.new("white_concrete_powder", 6)
    assert Inventory.get(next, 44) == ItemStack.new("white_concrete_powder", 64)
    assert Enum.all?(Inventory.table_contents(next), &(&1.count == 1))
    before = %{pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}, inventory: inv}
    after_snapshot = %{before | inventory: next}
    record = %{uuid: <<2::128>>, x: 0.5, y: 65.31999999284744, z: 0.5, stack: drop}

    assert {:ok, pending} =
             PlayerCraftingTransfers.prepare(
               <<1::128>>,
               0,
               before,
               after_snapshot,
               {0, 0},
               [record],
               {:quick_move, 0}
             )

    assert {:ok, bytes} = PlayerSnapshot.encode(<<1::128>>, pending)
    assert {:ok, loaded} = PlayerSnapshot.decode(bytes, <<1::128>>)
    assert loaded.inventory.table_inputs == next.table_inputs and loaded.outbox == pending.outbox
    invalid = put_in(after_snapshot.inventory.table_inputs, put_elem(next.table_inputs, 8, nil))

    assert {:error, :invalid_crafting_transfer} =
             PlayerCraftingTransfers.prepare(
               <<1::128>>,
               0,
               before,
               invalid,
               {0, 0},
               [record],
               {:quick_move, 0}
             )

    assert {:error, :invalid_crafting_transfer} =
             PlayerCraftingTransfers.prepare(
               <<1::128>>,
               0,
               before,
               after_snapshot,
               {0, 0},
               [%{record | stack: %{drop | count: 7}}],
               {:quick_move, 0}
             )
  end

  test "an ordinary crafted bundle can be taken onto an empty cursor and returned on close" do
    inv = %Inventory{slots: %{1 => ItemStack.new("string", 2), 3 => ItemStack.new("leather", 2)}}
    assert Inventory.crafting_result(inv) == ItemStack.new("bundle")
    {:ok, next, []} = Inventory.plan_click(inv, :pickup, 0, 0)

    assert next.carried == ItemStack.new("bundle") and
             Inventory.get(next, 1) == ItemStack.new("string")

    {:ok, next, []} = Inventory.close(next)

    assert next.slots == %{
             36 => ItemStack.new("bundle"),
             37 => ItemStack.new("string"),
             38 => ItemStack.new("leather")
           }

    assert next.carried == nil
  end
end
