defmodule Valimc.PlayerVitalsBoundsTest do
  # Bounds and fail-closed checks of health, food, armor, air, fire and consumable
  # rules. Their vanilla numbers are the vitals and effect oracle stages.
  use ExUnit.Case, async: true
  alias Valimc.Living.{Air, Burning, Effects, Freezing, Health}
  alias Valimc.{FoodItems}
  alias Valimc.{PlayerFood}
  alias Valimc.Protocol.{FoodProperties, ItemStack, ItemTypes, PotionContents, Wire}

  @fire 11
  defp rung(ticks \\ 200, amp \\ 1), do: {ticks, amp, false, true, true}
  defp props, do: %{nutrition: 5, saturation: 6.0, can_always_eat: false}

  test "saved health clamps at zero/max, persists native fields and rejects invalid records" do
    assert {:ok, damaged} = Health.set(%Health{}, 7.25)
    damaged = %{damaged | hurt_ticks: 7, death_ticks: 11, cooldown: 17, last_hurt: 5.0}
    assert {:ok, saved} = Health.saved(damaged)
    assert saved == %{value: 7.25, hurt_ticks: 7, death_ticks: 11}
    assert {:ok, restored} = Health.restore(saved)
    assert restored == %{damaged | cooldown: 0, last_hurt: 0.0}
    assert {:ok, %{value: 5.0, maximum: 5.0}} = Health.restore(saved, 5.0)
    assert {:ok, %{value: 1024.0, maximum: 1024.0}} = Health.restore(nil, 1024)
    assert {:ok, %{value: +0.0}} = Health.reduce(damaged, 8)
    assert {:ok, %{value: 20.0}} = Health.set(damaged, 200)

    for invalid <- [
          nil,
          %{saved | value: -1.0},
          %{saved | value: 1025.0},
          %{saved | value: 0.1},
          %{saved | hurt_ticks: 32768},
          %{saved | death_ticks: -1}
        ] do
      refute Health.valid_saved?(invalid)
    end

    for maximum <- [0, 1025, :bad] do
      assert {:error, :invalid_health} = Health.restore(saved, maximum)
    end
  end

  test "bounded canonical state excludes damaged persistence and supports native eligibility" do
    assert PlayerFood.valid?(%PlayerFood{})
    assert PlayerFood.enough?(%PlayerFood{level: 7})
    refute PlayerFood.enough?(%PlayerFood{level: 6})
    assert PlayerFood.needs?(%PlayerFood{level: 19})
    refute PlayerFood.needs?(%PlayerFood{})

    for {key, value} <- [
          level: -1,
          level: 21,
          saturation: -1.0,
          saturation: 21.1,
          saturation: 0.1,
          exhaustion: 40.1,
          exhaustion: -1.0,
          timer: -1,
          timer: 81
        ],
        do: refute(PlayerFood.valid?(Map.put(%PlayerFood{}, key, value)))
  end

  test "only an eye in water drains air; both bubble-column states replenish it" do
    water = 89
    assert Air.submerged?(true, water)
    refute Air.submerged?(false, water)
    for id <- Air.bubble_states(), do: refute(Air.submerged?(true, id))
  end

  # A tick without a body sample (its chunk unreadable) leaves the due hit for
  # the next sample: periods that pass meanwhile keep one hit, not one each.
  test "freezing keeps at most one due hit until a sample consumes it" do
    cold = %Freezing{frozen_ticks: 140}
    due = Enum.reduce(1..80, cold, fn _, env -> Freezing.tick(env, true) end)
    assert due.damage_due and due.damage_phase == 0
    assert {true, consumed} = Freezing.consume_damage(due, true)
    refute consumed.damage_due
    assert {false, ^consumed} = Freezing.consume_damage(consumed, true)
    assert {false, %{damage_due: false}} = Freezing.consume_damage(due, false)
  end

  test "fire contact work is bounded and unknown or malformed samples refuse" do
    assert {:ok, []} = Burning.plan([])
    assert {:ok, [:extinguish]} = Burning.plan([List.duplicate(:water, 2048)])

    for invalid <- [
          List.duplicate([], 2049),
          [List.duplicate(:fire, 2049)],
          [[:rain]],
          [nil],
          nil
        ] do
      assert {:error, :invalid_fire_contacts} = Burning.plan(invalid)
    end
  end

  test "invalid nutrition, nonfinite/negative saturation, booleans and truncated food cannot enter inventory" do
    invalid = [
      Wire.varint(-1) <> <<0.0::float-32, 0>>,
      <<0, -1.0::float-32, 0>>,
      <<0, 0x7FC00000::32, 0>>,
      <<0, 0x7F800000::32, 0>>,
      <<0, 0.0::float-32, 2>>,
      <<0>>,
      <<>>
    ]

    for payload <- invalid, mode <- [:trusted, :untrusted] do
      length = if mode == :untrusted, do: Wire.varint(byte_size(payload)), else: <<>>

      bytes =
        IO.iodata_to_binary([
          Wire.varint(1),
          Wire.varint(ItemTypes.id("stone")),
          <<1, 0>>,
          Wire.varint(ItemTypes.component_id("food")),
          length,
          payload
        ])

      assert {:error, _} = ItemStack.decode(bytes, mode)
    end

    for invalid <- [
          %{props() | nutrition: -1},
          %{props() | nutrition: 2_147_483_648},
          %{props() | saturation: -1.0},
          %{props() | can_always_eat: 1},
          Map.put(props(), :extra, 1)
        ],
        do: refute(FoodProperties.valid?(invalid))
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

  test "draw count/precision boundaries and non-stock listener policies cannot silently lose callbacks" do
    item = ItemStack.new("enchanted_golden_apple")
    props = FoodItems.properties(item)
    {:ok, callbacks} = Effects.food_policy(item, props)

    for draws <- [[], [0.0, 0.0], [-0.1], [1.0], [nil], [0.1]],
        do: assert(Effects.food_effects(callbacks, draws) == {:error, :invalid_food_effect_draws})

    assert Effects.food_policy(item, %{props | other_listeners: ["minecraft:potion_contents"]}) ==
             :unsupported

    assert Effects.food_policy(item, %{
             props
             | consumable: Map.put(props.consumable, "effects", 0)
           }) == :unsupported

    assert Effects.food_policy(
             ItemStack.new("apple"),
             FoodItems.properties(ItemStack.new("apple"))
           ) == :unsupported
  end

  test "only unchanged stock removal callbacks and listener sets are admitted" do
    for {name, policy} <- [{"milk_bucket", :all}, {"honey_bottle", :poison}] do
      stack = ItemStack.new(name)
      props = FoodItems.properties(stack)
      assert {:ok, ^policy} = Effects.removal_policy(stack, props)
      assert :unsupported = Effects.removal_policy(stack, %{props | consumable: nil})

      assert :unsupported =
               Effects.removal_policy(stack, %{
                 props
                 | consumable: Map.put(props.consumable, "effects", 0)
               })

      assert :unsupported =
               Effects.removal_policy(stack, %{
                 props
                 | other_listeners: ["minecraft:potion_contents"]
               })
    end

    apple = ItemStack.new("golden_apple")
    assert :unsupported = Effects.removal_policy(apple, FoodItems.properties(apple))
  end
end
