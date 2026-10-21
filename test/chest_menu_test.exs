defmodule Valimc.ChestMenuTest do
  use ExUnit.Case, async: true
  alias Valimc.{ChestMenu, Inventory}

  test "bad dimensions and special click sentinels do not become physical slot addresses" do
    for rows <- [0, 7, nil, 3.5],
        do: assert(ChestMenu.type(rows) == {:error, :invalid_chest_rows})

    for slot <- [-999, -1, nil, 1.5, 1000],
        do: assert(ChestMenu.address(3, slot) == {:error, :invalid_chest_slot})

    assert {:error, :invalid_chest_contents} = ChestMenu.contents(3, {}, %Inventory{})
  end
end
