defmodule Valimc.AnvilBlockEntityTest do
  @moduledoc "Vanilla block entity compounds and item tags as ValiMC holds them (VMC-021e1)."
  use ExUnit.Case, async: true
  alias Valimc.Storage.Anvil.BlockEntity
  alias Valimc.Data.NBT
  alias Valimc.Blocks.BlockEntityTypes, as: Types
  alias Valimc.Protocol.{ItemData, ItemStack}
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.World.BlockEntities

  @chest BlockRegistry.default_state("chest")
  @furnace BlockRegistry.default_state("furnace")
  @sign BlockRegistry.default_state("oak_sign")
  @stone BlockRegistry.default_state("stone")

  defp stack(name, count, components \\ %{}),
    do: %{ItemStack.new(name, count) | components: components}

  defp compound(fields), do: {:compound, fields}

  defp be(id, {x, y, z}, extra \\ %{}) do
    compound(
      Map.merge(
        %{
          "id" => {:string, id},
          "x" => {:int, x},
          "y" => {:int, y},
          "z" => {:int, z},
          "keepPacked" => {:byte, 0},
          "components" => compound(%{})
        },
        extra
      )
    )
  end

  defp item_tag(stack, slot) do
    {:compound, fields} = ItemData.tag(stack)
    Map.put(fields, "Slot", {:byte, slot})
  end

  describe "item tags" do
    test "unsupported components, bad counts and unknown items are reported, air is empty" do
      book =
        compound(%{
          "id" => {:string, "minecraft:writable_book"},
          "count" => {:int, 1},
          "components" =>
            compound(%{"minecraft:writable_book_content" => compound(%{"pages" => NBT.list([])})})
        })

      assert ItemData.stack(book) == {:unsupported, ["minecraft:writable_book_content"]}
      bad = compound(%{"id" => {:string, "minecraft:stone"}, "count" => {:int, 100}})
      assert ItemData.stack(bad) == {:error, :invalid_item_count}
      unknown = compound(%{"id" => {:string, "minecraft:nope"}, "count" => {:int, 1}})
      assert ItemData.stack(unknown) == {:error, :unknown_item}
      assert ItemData.stack(compound(%{"id" => {:string, "minecraft:air"}})) == {:ok, nil}
      # Bounds the network encoder enforces: damageable items do not stack.
      swords = compound(%{"id" => {:string, "minecraft:diamond_sword"}, "count" => {:int, 2}})
      assert {:error, _} = ItemData.stack(swords)
    end
  end

  describe "block entities" do
    test "a chest holding only items it can hold becomes an owned container" do
      sword = stack("diamond_sword", 1, %{"minecraft:damage" => 3})
      items = NBT.list([compound(item_tag(sword, 0)), compound(item_tag(stack("dirt", 5), 26))])
      tag = be("minecraft:chest", {1, 64, 2}, %{"Items" => items})
      assert {:ok, {1, 64, 2}, {:chest, slots}} = BlockEntity.convert(tag, @chest)
      assert elem(slots, 0) == sword and elem(slots, 26) == stack("dirt", 5)
      assert slots |> Tuple.to_list() |> Enum.count(&(&1 != nil)) == 2
    end

    test "names, locks, loot tables and items ValiMC cannot hold leave the chest preserved" do
      chest = Types.type_id(@chest)

      for extra <- [
            %{"CustomName" => {:string, "Named"}},
            %{"LootTable" => {:string, "minecraft:chests/village/village_plains_house"}},
            %{"components" => compound(%{"minecraft:custom_name" => {:string, "x"}})},
            %{
              "Items" =>
                NBT.list([
                  compound(%{
                    "Slot" => {:byte, 0},
                    "id" => {:string, "minecraft:writable_book"},
                    "count" => {:int, 1},
                    "components" =>
                      compound(%{
                        "minecraft:writable_book_content" => compound(%{"pages" => NBT.list([])})
                      })
                  })
                ])
            }
          ] do
        tag = be("minecraft:chest", {0, 64, 0}, extra)
        assert BlockEntity.convert(tag, @chest) == {:ok, {0, 64, 0}, {:preserved, chest}}
        assert BlockEntity.holds_data?(tag)
      end
    end

    test "a furnace's items, times, speed and recipe uses become a cooking entry" do
      tag =
        be("minecraft:furnace", {0, 64, 0}, %{
          "Items" =>
            NBT.list([
              compound(item_tag(stack("raw_iron", 5), 0)),
              compound(item_tag(stack("coal", 3), 1)),
              compound(item_tag(stack("iron_ingot", 2), 2))
            ]),
          "cooking_time_spent" => {:int, 50},
          "cooking_total_time" => {:int, 200},
          "lit_time_remaining" => {:int, 1000},
          "lit_total_time" => {:int, 1600},
          "speed_multiplier" => NBT.float(1.0),
          "RecipesUsed" => compound(%{"minecraft:iron_ingot_from_smelting_raw_iron" => {:int, 2}})
        })

      assert {:ok, _, {:cooking, entry}} = BlockEntity.convert(tag, @furnace)
      assert entry.kind == :furnace
      assert entry.recipes == %{"minecraft:iron_ingot_from_smelting_raw_iron" => 2}

      assert %{progress: 50, total: 200, burn_left: 1000, burn_total: 1600, speed: 1.0} =
               entry.cooking

      assert elem(entry.cooking.slots, 1) == stack("coal", 3)
    end
  end

  describe "preserved block entities" do
    defp preserved(tag, state) do
      {:ok, nbt} = BlockEntities.encode_nbt(tag)
      {:ok, entities} = BlockEntities.new(%{{1, 64, 1} => {Types.type_id(state), nbt}})
      entities
    end

    test "stored entries round trip, render while their block lives and protect their data" do
      sign =
        be("minecraft:sign", {1, 64, 1}, %{
          "front_text" => compound(%{"color" => {:string, "red"}})
        })

      entities = preserved(sign, @sign)
      assert {:ok, ^entities} = BlockEntities.new(BlockEntities.stored(entities))

      assert [{{1, 64, 1}, type, update}] =
               BlockEntities.chunk_entries(entities, {0, 0}, %{{1, 64, 1} => @sign})

      assert type == Types.type_id(@sign) and is_binary(update)
      assert BlockEntities.chunk_entries(entities, {0, 0}, %{{1, 64, 1} => @stone}) == []
      assert BlockEntities.chunk_entries(entities, {1, 0}, %{}) == []

      current = fn _ -> @sign end
      assert BlockEntities.protected?(entities, %{{1, 64, 1} => 0}, current)
      waterlogged = BlockRegistry.state("oak_sign", %{"waterlogged" => "true", "rotation" => "0"})
      refute BlockEntities.protected?(entities, %{{1, 64, 1} => waterlogged}, current)
      refute BlockEntities.protected?(entities, %{{2, 64, 1} => 0}, current)
      # A stale entry (its block already replaced) protects nothing.
      refute BlockEntities.protected?(entities, %{{1, 64, 1} => 0}, fn _ -> @stone end)
    end

    test "an entry without data can be removed with its block; invalid stores are refused" do
      empty = preserved(be("minecraft:sign", {1, 64, 1}), @sign)
      refute BlockEntities.protected?(empty, %{{1, 64, 1} => 0}, fn _ -> @sign end)
      assert [{_, _, nil}] = BlockEntities.chunk_entries(empty, {0, 0}, %{{1, 64, 1} => @sign})

      assert {:error, _} = BlockEntities.new(%{{0, 0, 0} => {9999, <<>>}})
      assert {:error, _} = BlockEntities.new(%{{0, 0, 0} => {1, <<1, 2, 3>>}})
      assert {:error, _} = BlockEntities.new(%{"x" => 1})
    end
  end
end
