defmodule Valimc.SpawnInputsTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.World.SpawnInputs

  test "an owner's bodies that are not mobs are boxes" do
    body = Body.primed_tnt(80)

    {:ok, store, _} =
      Store.create_record(
        Store.new(),
        {0, 0},
        Store.body_record(body, <<1::128>>, {1.5, 64.0, 0.5})
      )

    [box] = SpawnInputs.bodies(store.entries)
    {x0, 64.0, _, x1, _, _} = box
    assert x0 < 1.5 and x1 > 1.5
    assert [] = SpawnInputs.bodies(%{})
  end
end
