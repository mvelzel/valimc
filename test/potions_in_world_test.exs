defmodule Valimc.PotionsInWorldTest do
  @moduledoc """
  Potions in the world (VMC-034o3): a lingering potion's cloud, tipped
  arrows (their effects, colour and recipe) and water bottles on cauldrons.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Cauldron
  alias Valimc.Data.{Blocks, EffectTypes, PotionTypes}
  alias Valimc.Entity.{EffectCloud, Projectile}
  alias Valimc.Protocol.{ItemStack, PotionContents}

  defp contents(name), do: %{PotionContents.empty() | potion: PotionTypes.id(name)}

  defp potion(item, name),
    do: %{ItemStack.new(item) | components: %{"minecraft:potion_contents" => contents(name)}}

  defp target(n, at),
    do: %{
      ref: {:mob, n},
      uuid: <<n::128>>,
      position: at,
      box:
        {elem(at, 0) - 0.3, 64.0, elem(at, 2) - 0.3, elem(at, 0) + 0.3, 65.8, elem(at, 2) + 0.3},
      type: "minecraft:zombie"
    }

  test "a lingering cloud waits, gives a quarter of its potion and shrinks with each touch" do
    cloud = EffectCloud.lingering(nil, contents("swiftness"), 0.25)
    assert cloud.data.wait == 10 and cloud.data.radius == 3.0
    assert {_, {:color, color}} = cloud.data.particle
    assert color == Bitwise.bor(0xFF000000, 0x33EBFF)

    # Its tenth tick is the first after waiting; touches come every fifth.
    {cloud, effects} =
      Enum.reduce(1..10, {cloud, []}, fn _, {cloud, _} ->
        {:keep, next, effects} =
          EffectCloud.tick(cloud, {0.0, 64.0, 0.0}, [target(1, {0.5, 64.0, 0.0})])

        {next, effects}
      end)

    speed = EffectTypes.id("speed")
    assert [{:effect, %{ref: {:mob, 1}}, ^speed, [{900, 0, false, true, true}]}] = effects
    assert cloud.data.radius < 2.6
  end

  test "a tipped arrow carries every effect at an eighth, its colour, and is crafted of eight arrows" do
    arrow = Projectile.new("minecraft:arrow", nil, potion("tipped_arrow", "turtle_master"))
    assert [{slowness, {50, 3, _, _, _}}, {resistance, {50, 2, _, _, _}}] = arrow.data.effects
    assert slowness == EffectTypes.id("slowness") and resistance == EffectTypes.id("resistance")
    assert arrow.data.color != -1

    grid =
      List.duplicate(ItemStack.new("arrow"), 4) ++
        [potion("lingering_potion", "poison")] ++
        List.duplicate(ItemStack.new("arrow"), 4)

    assert {:ok,
            %ItemStack{count: 8, components: %{"minecraft:potion_contents" => made}} = tipped} =
             Valimc.Menus.Crafting.result(grid)

    assert made.potion == PotionTypes.id("poison") and
             tipped.item_id == ItemStack.new("tipped_arrow").item_id
  end

  test "water bottles fill a cauldron a level at a time and glass bottles take it back" do
    empty = Blocks.default_state("cauldron")
    level = fn n -> Blocks.state("water_cauldron", %{"level" => "#{n}"}) end
    assert Cauldron.use_of(potion("potion", "water")) == :pour
    assert Cauldron.use_of(potion("potion", "awkward")) == nil
    assert Cauldron.use_of(ItemStack.new("glass_bottle")) == :fill
    assert {:ok, level.(1)} == Cauldron.apply(empty, :pour)
    assert {:ok, level.(3)} == Cauldron.apply(level.(2), :pour)
    assert :pass == Cauldron.apply(level.(3), :pour)
    assert {:ok, empty} == Cauldron.apply(level.(1), :fill)
    assert :pass == Cauldron.apply(empty, :fill)
  end
end
