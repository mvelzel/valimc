defmodule Valimc.PotionContentsTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.{EffectTypes, ItemStack, ItemTypes, PotionContents, PotionTypes, Wire}

  @fire 11
  defp rung(ticks \\ 200, amp \\ 1), do: {ticks, amp, false, true, true}

  defp stack(value),
    do: %{ItemStack.new("potion") | components: %{"minecraft:potion_contents" => value}}

  test "stock and custom contents retain exact hidden state through both wire formats and player journals" do
    contents = %{
      PotionContents.empty()
      | potion: PotionTypes.id("fire_resistance"),
        color: -1,
        name: "é😀",
        effects: [{@fire, [rung(), rung(600, 3)]}]
    }

    potion = stack(contents)

    for mode <- [:trusted, :untrusted] do
      bytes = potion |> ItemStack.encode(mode) |> IO.iodata_to_binary()
      assert {:ok, ^potion} = ItemStack.decode(bytes, mode)
    end

    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    snapshot = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => potion}})
    assert {:ok, encoded} = PlayerSnapshot.encode(<<13::128>>, snapshot)
    assert {:ok, saved} = PlayerSnapshot.decode(encoded, <<13::128>>)
    assert saved.inventory.slots[36] == potion

    no_hidden = stack(%{contents | effects: [{@fire, [rung()]}]})
    assert ItemStack.same_item?(potion, no_hidden)
    refute ItemStack.same_item?(potion, stack(%{contents | color: 0}))
    refute ItemStack.same_item?(potion, stack(%{contents | name: nil}))
    refute ItemStack.same_item?(potion, stack(%{contents | effects: [{@fire, [rung(201)]}]}))

    for name <- ~w(potion splash_potion lingering_potion tipped_arrow) do
      plain = ItemStack.new(name)

      assert ItemStack.same_item?(plain, %{
               plain
               | components: %{"minecraft:potion_contents" => PotionContents.empty()}
             })

      refute ItemStack.same_item?(plain, %{
               plain
               | removed: MapSet.new(["minecraft:potion_contents"])
             })
    end
  end

  test "delivery keeps native base/custom order, head-only copying and float32 duration boundaries" do
    contents = %{
      PotionContents.empty()
      | potion: PotionTypes.id("fire_resistance"),
        effects: [
          {@fire, [rung(3, 2), rung(600, 0)]},
          {EffectTypes.id("water_breathing"), [rung(-1)]}
        ]
    }

    assert [
             {@fire, [{1800, 0, false, true, true}]},
             {@fire, [{1, 2, false, true, true}]},
             {12, [{-1, 1, false, true, true}]}
           ] = PotionContents.effects(contents, 0.5)

    assert [{@fire, [{9600, 0, false, true, true}]}] =
             PotionContents.effects(%{
               PotionContents.empty()
               | potion: PotionTypes.id("long_fire_resistance")
             })

    for ticks <- [-1, 0, -2, -2_147_483_648, 2_147_483_647] do
      value = %{PotionContents.empty() | effects: [{@fire, [rung(ticks)]}]}
      [{@fire, [{actual, _, _, _, _}]}] = PotionContents.effects(value, 3.4028234663852886e38)

      expected =
        cond do
          ticks in [-1, 0] -> ticks
          ticks < 0 -> 1
          true -> 2_147_483_647
        end

      assert actual == expected
    end

    for invalid <- [-1.0, 3.5e38, nil],
        do: assert_raise(ArgumentError, fn -> PotionContents.effects(contents, invalid) end)
  end

  test "a potion patch on ordinary food cannot silently discard its specialized listener" do
    bread = ItemStack.new("bread")
    assert Valimc.FoodItems.plain?(Valimc.FoodItems.properties(bread))

    patched = %{
      bread
      | components: %{
          "minecraft:potion_contents" => %{
            PotionContents.empty()
            | potion: PotionTypes.id("fire_resistance")
          }
        }
    }

    properties = Valimc.FoodItems.properties(patched)
    assert properties.other_listeners == ["minecraft:potion_contents"]
    refute Valimc.FoodItems.plain?(properties)
    refute Valimc.FoodItems.plain?(Valimc.FoodItems.properties(ItemStack.new("potion")))
  end

  test "global rung/list/name budgets bound parsing without imposing the owned-state amplifier ordering" do
    maximum = %{
      PotionContents.empty()
      | effects: [{@fire, List.duplicate(rung(), 256)}],
        name: String.duplicate("x", 32_767)
    }

    assert PotionContents.valid?(maximum)

    {^maximum, <<9>>} =
      PotionContents.take(IO.iodata_to_binary([PotionContents.encode(maximum), <<9>>]))

    for bad <- [
          %{maximum | effects: [{@fire, List.duplicate(rung(), 257)}]},
          %{maximum | effects: List.duplicate({@fire, [rung()]}, 65)},
          %{maximum | effects: [{@fire, []}]},
          %{maximum | effects: [{40, [rung()]}]},
          %{maximum | effects: [{@fire, [rung(0, 256)]}]},
          %{maximum | effects: [{@fire, [rung(-2_147_483_649)]}]},
          %{maximum | name: String.duplicate("x", 32_768)},
          %{maximum | name: <<255>>},
          %{maximum | potion: 46},
          %{maximum | color: 2_147_483_648},
          Map.put(maximum, :extra, 0)
        ],
        do: refute(PotionContents.valid?(bad))

    valid = PotionContents.empty() |> PotionContents.encode() |> IO.iodata_to_binary()
    assert valid == <<0, 0, 0, 0>>
    detail = [Wire.varint(1), Wire.varint(200), <<0, 1, 1, 1>>]

    invalid = [
      <<2>>,
      <<1, 46>>,
      <<0, 0, 65>>,
      <<0, 0, 1, 40>>,
      <<0, 0, 1, 11, 0>>,
      <<0, 0, 1, 11, 0, 1, 2, 1, 1, 0, 0>>,
      IO.iodata_to_binary([<<0, 0, 1, 11>>, List.duplicate(detail, 256)])
    ]

    for payload <- invalid, mode <- [:trusted, :untrusted] do
      length = if mode == :untrusted, do: Wire.varint(byte_size(payload)), else: <<>>

      wire =
        IO.iodata_to_binary([
          <<1>>,
          Wire.varint(ItemTypes.id("potion")),
          <<1, 0>>,
          Wire.varint(ItemTypes.component_id("potion_contents")),
          length,
          payload
        ])

      assert {:error, _} = ItemStack.decode(wire, mode)
    end
  end
end
