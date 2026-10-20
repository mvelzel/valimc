defmodule Valimc.AnvilEntityTest do
  @moduledoc "Vanilla entity compounds as ValiMC holds them (VMC-021e2)."
  use ExUnit.Case, async: true
  alias Valimc.Anvil.Entity
  alias Valimc.NBT
  alias Valimc.Protocol.{ItemData, ItemStack}

  @uuid <<1::32, 2::32, 3::32, 4::32>>

  defp doubles(values), do: {:list, {:double, Enum.map(values, &<<&1 * 1.0::float-64>>)}}

  defp item(extra \\ %{}) do
    {:compound,
     Map.merge(
       %{
         "id" => {:string, "minecraft:item"},
         "UUID" => {:int_array, @uuid},
         "Pos" => doubles([1.5, 70.0, -2.25]),
         "Motion" => doubles([0.1, -0.2, 0.0]),
         "Age" => {:short, 120},
         "PickupDelay" => {:short, 10},
         "OnGround" => {:byte, 1},
         "Item" => ItemData.tag(ItemStack.new("stone", 3))
       },
       extra
     )}
  end

  test "a dropped item becomes an item record as vanilla loads it" do
    assert {:item, record} = Entity.convert(item())
    assert record.uuid == @uuid and {record.x, record.y, record.z} == {1.5, 70.0, -2.25}
    assert record.stack == ItemStack.new("stone", 3)

    assert %{velocity: {0.1, -0.2, +0.0}, age: 120, pickup_delay: 10, on_ground: true} =
             record.motion

    # Motion beyond ±10 is zero; age past 6,000 despawns; a negative delay never ends.
    {:item, odd} =
      Entity.convert(
        item(%{
          "Motion" => doubles([11.0, -10.0, -12.5]),
          "Age" => {:short, 9000},
          "PickupDelay" => {:short, -5}
        })
      )

    assert odd.motion.velocity == {0.0, -10.0, 0.0}
    assert odd.motion.age == 6000 and odd.motion.pickup_delay == 32_767
  end

  test "owned, riding and unsupported items and every other entity are preserved" do
    book = %{
      "Item" =>
        {:compound,
         %{
           "id" => {:string, "minecraft:writable_book"},
           "count" => {:int, 1},
           "components" =>
             {:compound,
              %{"minecraft:writable_book_content" => {:compound, %{"pages" => NBT.list([])}}}}
         }}
    }

    for extra <- [
          %{"Owner" => {:int_array, @uuid}},
          %{"Passengers" => NBT.list([item()])},
          %{"Pos" => doubles([4.0e7, 70.0, 0.0])},
          %{"UUID" => {:int_array, <<1::32>>}},
          book,
          %{"id" => {:string, "minecraft:experience_orb"}}
        ],
        do: assert(Entity.convert(item(extra)) == :preserve)
  end

  test "an item record writes back to a compound that converts to the same record" do
    {:item, record} = Entity.convert(item())
    assert Entity.convert(Entity.item_tag(record)) == {:item, record}
  end

  test "an XP orb becomes an imported birth with its body; its compound converts back" do
    orb = fn extra ->
      {:compound,
       Map.merge(
         %{
           "id" => {:string, "minecraft:experience_orb"},
           "UUID" => {:int_array, @uuid},
           "Pos" => doubles([4.5, 64.0, 4.5]),
           "Motion" => doubles([0.0, -0.08, 0.0]),
           "Age" => {:short, 150},
           "Value" => {:short, 7},
           "Count" => {:int, 3},
           "OnGround" => {:byte, 1}
         },
         extra
       )}
    end

    assert {:orb, converted} = Entity.convert(orb.(%{}))

    assert %{uuid: @uuid, position: {4.5, 64.0, 4.5}, age: 150, value: 7, count: 3} = converted
    assert converted.on_ground and not converted.no_gravity
    assert {:orb, %{age: 5999}} = Entity.convert(orb.(%{"Age" => {:short, 7000}}))
    assert {:orb, %{count: 1}} = Entity.convert(orb.(%{"Count" => nil}) |> drop_nil())

    for bad <- [
          %{"Value" => {:short, 0}},
          %{"Count" => {:int, 0}},
          %{"Passengers" => NBT.list([])}
        ],
        do: assert(Entity.convert(orb.(bad)) == :preserve)

    tag = Entity.orb_tag(@uuid, 7, 3, converted)
    assert Entity.convert(tag) == {:orb, converted}
  end

  defp drop_nil({:compound, fields}),
    do: {:compound, Map.reject(fields, fn {_, v} -> v == nil end)}
end
