defmodule Valimc.CookingEntryTest do
  use ExUnit.Case, async: true
  alias Valimc.{Cooking, CookingRecipes}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.{Containers, CookingEntry}

  test "mixed cooking/chest snapshots preserve exact progress, patches and independent typed receipts" do
    key = {0, 0}
    pos = {0, 64, 0}
    source = <<1::128>>
    receipt = %{sequence: 79, digest: :crypto.hash(:sha256, "typed")}
    {:ok, chests, _} = Containers.create(%Containers{}, key, pos, 3)
    assert {:ok, <<"VMCCONTS", 1, _::binary>>} = Containers.encode(key, chests)
    chests = %{chests | receipts: %{source => receipt}}
    assert {:ok, <<"VMCCONTS", 2, _::binary>>} = Containers.encode(key, chests)

    {:ok, recipe} =
      CookingRecipes.find(ItemStack.new("raw_iron"), Data.item_block(Data.item("furnace")))

    item = %{
      ItemStack.new("raw_iron", 3)
      | components: %{"minecraft:custom_name" => {:string, "Input"}},
        removed: MapSet.new(["minecraft:rarity"])
    }

    state =
      Enum.reduce(Enum.with_index([:furnace, :smoker, :blast_furnace], 1), chests, fn {kind, x},
                                                                                      current ->
        {:ok, current, entry} = Containers.create_cooking(current, key, {x, 64, 0}, kind)

        cooking = %Cooking{
          slots: {item, ItemStack.new("coal", 2), ItemStack.new("iron_ingot")},
          burn_left: 177,
          burn_total: 300,
          progress: 99,
          total: 200,
          speed: 2.0
        }

        {:ok, current, _} =
          Containers.replace_cooking(current, {x, 64, 0}, entry.revision, cooking, %{
            recipe.key => 43
          })

        current
      end)

    assert {:ok, <<"VMCCONTS", 3, _::binary>> = bytes} = Containers.encode(key, state)
    assert {:ok, ^state} = Containers.decode(bytes, key)
    assert state.receipts == chests.receipts and state.entries[pos] == chests.entries[pos]

    assert {:error, :stale_container} =
             Containers.replace_cooking(state, {1, 64, 0}, 2, %Cooking{}, %{})

    assert {:error, :stale_container} =
             Containers.replace(
               state,
               {1, 64, 0},
               state.entries[{1, 64, 0}].revision,
               Tuple.duplicate(nil, 27)
             )

    assert {:error, :stale_container} = Containers.replace_cooking(state, pos, 1, %Cooking{}, %{})
  end

  test "invalid progress, recipe uses and noncanonical items refuse the whole generation" do
    {:ok, state, entry} = Containers.create_cooking(%Containers{}, {0, 0}, {0, 64, 0}, :furnace)

    for cooking <- [
          %Cooking{burn_left: 20_001},
          %Cooking{speed: 1.5},
          %Cooking{progress: -1},
          %Cooking{slots: {ItemStack.new("air"), nil, nil}},
          %Cooking{slots: {ItemStack.new("stone", 100), nil, nil}}
        ] do
      assert {:error, :invalid_cooking_entry} =
               Containers.replace_cooking(state, {0, 64, 0}, entry.revision, cooking, %{})

      assert state.sequence == 1 and state.entries[{0, 64, 0}] == entry
    end

    for recipes <- [
          %{"minecraft:missing" => 1},
          %{"minecraft:iron_ingot_from_smelting_raw_iron" => 0},
          %{"minecraft:iron_ingot_from_smelting_raw_iron" => 2_147_483_648}
        ] do
      assert {:error, :invalid_cooking_entry} =
               Containers.replace_cooking(state, {0, 64, 0}, entry.revision, %Cooking{}, recipes)
    end

    assert {:error, :invalid_cooking_entry} =
             Containers.create_cooking(state, {0, 0}, {1, 64, 0}, :missing)

    assert {:error, :invalid_container_position} =
             Containers.create_cooking(state, {0, 0}, {128, 64, 0}, :furnace)

    exhausted = %{state | sequence: 18_446_744_073_709_551_615}

    assert {:error, :container_sequence_exhausted} =
             Containers.replace_cooking(exhausted, {0, 64, 0}, entry.revision, %Cooking{}, %{})
  end

  test "malformed typed payloads, trailing bytes and rehashed unknown discriminators fail closed" do
    {:ok, state, entry} = Containers.create_cooking(%Containers{}, {0, 0}, {0, 64, 0}, :smoker)
    {:ok, bytes} = CookingEntry.encode(entry)
    <<kind, fields::binary-size(16), _speed, rest::binary>> = bytes

    for bad <- [
          <<kind, fields::binary, 0, rest::binary>>,
          <<3, fields::binary, 1, rest::binary>>,
          bytes <> <<0>>,
          binary_part(bytes, 0, byte_size(bytes) - 1)
        ] do
      assert {:error, :invalid_cooking_entry} = CookingEntry.decode(bad, entry.revision)
    end

    {:ok, bytes} = Containers.encode({0, 0}, state)
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), _::binary>> = bytes
    <<prefix::binary-size(53), _tag, suffix::binary>> = payload
    bad = <<prefix::binary, 2, suffix::binary>>

    assert {:error, :invalid_container_snapshot} =
             Containers.decode(bad <> :crypto.hash(:sha256, bad), {0, 0})

    assert {:error, :invalid_container_snapshot} = Containers.decode(bytes, {1, 0})
  end
end
