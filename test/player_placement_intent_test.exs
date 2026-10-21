defmodule Valimc.PlayerPlacementIntentTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerPlacementIntent}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{MiningTransfers, PlacementRequest}
  @source <<1::128>>
  @permit <<2::128>>

  defp intent(count \\ 17) do
    before = %{
      ItemStack.new("stone", count)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    %{
      kind: :placement,
      key: {0, 0},
      permit: @permit,
      slot: 36,
      before: before,
      after: if(count == 1, do: nil, else: %{before | count: count - 1}),
      request: %{
        hand: :main,
        position: {1, 64, 1},
        face: 1,
        cursor: {0.5, 0.5, 0.5},
        inside: false,
        border: false,
        sequence: 7
      },
      expected: %{{1, 64, 1} => 0},
      edits: %{{1, 64, 1} => 1}
    }
  end

  test "typed intents preserve exact patches and single-item depletion in either hand" do
    for {count, hand} <- [{1, :off}, {17, :main}] do
      original = intent(count)

      original = %{
        original
        | slot: if(hand == :main, do: 36, else: 45),
          request: %{original.request | hand: hand}
      }

      assert {:ok, bytes} = PlayerPlacementIntent.encode(@source, 1, original)
      assert byte_size(bytes) <= PlayerPlacementIntent.max_bytes()
      assert {:ok, ^original} = PlayerPlacementIntent.decode(@source, 1, bytes)

      assert {:error, :invalid_placement_intent} =
               PlayerPlacementIntent.decode(<<3::128>>, 1, bytes)

      assert {:error, :invalid_placement_intent} = PlayerPlacementIntent.decode(@source, 2, bytes)
    end
  end

  test "saved chest orientation round trips without transient yaw and rejects wrong wetness or target" do
    original = intent(2)
    stack = ItemStack.new("chest", 2)

    for {yaw, fluid} <- [{0.0, 0}, {90.0, 89}, {270.0, 105}] do
      {:ok, state} = Valimc.Physics.ChestPlacement.single_state(yaw, fluid)

      chest = %{
        original
        | before: stack,
          after: %{stack | count: 1},
          expected: %{{1, 64, 1} => fluid},
          edits: %{{1, 64, 1} => state}
      }

      assert {:ok, bytes} = PlayerPlacementIntent.encode(@source, 1, chest)
      assert {:ok, ^chest} = PlayerPlacementIntent.decode(@source, 1, bytes)
      assert <<"VMCPOUT", 1, _::binary>> = bytes
      invalid = %{chest | edits: %{{1, 64, 1} => state + if(fluid == 89, do: 1, else: -1)}}

      assert {:error, :invalid_placement_intent} =
               PlayerPlacementIntent.encode(@source, 1, invalid)

      assert {:error, :invalid_placement_intent} =
               PlayerPlacementIntent.encode(@source, 1, %{chest | edits: %{{2, 64, 1} => state}})
    end
  end

  test "named chests cannot enter a source intent before owned name metadata exists" do
    original = intent(2)

    stack = %{
      ItemStack.new("chest", 2)
      | components: %{"minecraft:custom_name" => {:string, "Named"}}
    }

    {:ok, state} = Valimc.Physics.ChestPlacement.single_state(0.0, 0)

    chest = %{
      original
      | before: stack,
        after: %{stack | count: 1},
        edits: %{original.request.position => state}
    }

    assert {:error, :invalid_placement_intent} = PlayerPlacementIntent.encode(@source, 1, chest)
  end

  test "native candidate and count fences reject arbitrary blocks, changed patches and excess consumption" do
    original = intent()

    for invalid <- [
          %{original | after: nil},
          %{original | after: %{original.after | count: 15}},
          %{original | after: %{original.after | components: %{}}},
          %{original | before: ItemStack.new("egg", 17)},
          %{original | edits: %{{1, 64, 1} => 15}},
          %{original | slot: 45},
          %{original | expected: %{{1, 64, 1} => 1}},
          %{original | expected: %{{2, 64, 1} => 0}},
          %{original | request: %{original.request | cursor: :nonfinite}},
          %{original | request: %{original.request | cursor: {5.0, 0.5, 0.5}}}
        ] do
      assert {:error, :invalid_placement_intent} =
               PlayerPlacementIntent.encode(@source, 1, invalid)
    end

    slab = ItemStack.new("oak_slab", 2)

    wet = %{
      original
      | before: slab,
        after: %{slab | count: 1},
        request: %{original.request | position: {1, 63, 1}},
        expected: %{{1, 63, 1} => 1, {1, 64, 1} => 89},
        edits: %{{1, 64, 1} => 15_179}
    }

    assert {:ok, bytes} = PlayerPlacementIntent.encode(@source, 1, wet)
    assert {:ok, ^wet} = PlayerPlacementIntent.decode(@source, 1, bytes)

    assert {:error, :invalid_placement_intent} =
             PlayerPlacementIntent.encode(@source, 1, %{wet | edits: %{{1, 64, 1} => 15_177}})
  end

  test "the pending inventory must retain the exact consumed hand and selection" do
    original = intent()
    inventory = %Inventory{slots: %{36 => original.after}}
    assert PlayerPlacementIntent.matches_inventory?(original, inventory)
    refute PlayerPlacementIntent.matches_inventory?(original, %{inventory | selected: 1})

    refute PlayerPlacementIntent.matches_inventory?(original, %{
             inventory
             | slots: %{36 => original.before}
           })

    off = %{original | slot: 45, request: %{original.request | hand: :off}}

    assert PlayerPlacementIntent.matches_inventory?(off, %{
             inventory
             | selected: 8,
               slots: %{45 => original.after}
           })

    depleted = %{intent(1) | slot: 45, request: %{original.request | hand: :off}}
    assert PlayerPlacementIntent.matches_inventory?(depleted, %Inventory{})
  end

  test "truncation, overlong fields and noncanonical native booleans cannot become intents" do
    assert {:ok, bytes} = PlayerPlacementIntent.encode(@source, 1, intent())

    for size <- 0..(byte_size(bytes) - 1) do
      assert {:error, :invalid_placement_intent} =
               PlayerPlacementIntent.decode(@source, 1, binary_part(bytes, 0, size))
    end

    assert {:error, :invalid_placement_intent} =
             PlayerPlacementIntent.decode(@source, 1, bytes <> <<0>>)

    <<header::binary-size(9), _before::32, tail::binary>> = bytes

    assert {:error, :invalid_placement_intent} =
             PlayerPlacementIntent.decode(
               @source,
               1,
               <<header::binary, 0xFFFFFFFF::32, tail::binary>>
             )

    <<_::binary-size(9), before_size::32, after_size::32, _::binary>> = bytes
    inside_offset = 19 + before_size + after_size + 22
    <<prefix::binary-size(^inside_offset), 0, suffix::binary>> = bytes

    assert {:error, :invalid_placement_intent} =
             PlayerPlacementIntent.decode(@source, 1, <<prefix::binary, 2, suffix::binary>>)
  end

  test "request identity binds source, sequence, permit and block outcome in a separate domain" do
    original = intent()
    assert {:ok, key, request, digest} = PlayerPlacementIntent.request(@source, 1, original)
    assert {:ok, bytes} = PlacementRequest.encode(key, request)
    assert byte_size(bytes) == 90
    assert {:ok, ^request} = PlacementRequest.decode(bytes, key)

    assert {:ok, mining_digest} =
             MiningTransfers.digest(key, Map.put(Map.delete(request, :edits), :records, []))

    refute digest == mining_digest

    for changed <- [
          %{request | source: <<3::128>>},
          %{request | sequence: 2},
          %{request | permit: <<4::128>>},
          %{request | expected: %{{1, 64, 1} => 2}},
          %{request | edits: %{{1, 64, 1} => 15}}
        ] do
      assert {:ok, changed_digest} = PlacementRequest.digest(key, changed)
      refute changed_digest == digest
    end

    for invalid <- [
          %{request | sequence: 0},
          %{request | expected: %{}},
          %{request | edits: request.expected},
          %{request | edits: %{{129, 64, 1} => 1}},
          %{request | expected: %{{1, 64, 1} => 35_723}}
        ] do
      assert {:error, :invalid_placement_request} = PlacementRequest.encode(key, invalid)
    end

    assert {:error, :invalid_placement_request} = PlacementRequest.decode(bytes, {1, 0})
    assert {:error, :invalid_placement_request} = PlacementRequest.decode(bytes <> <<0>>, key)
  end

  test "two-block contexts require unique canonical entries and exact uint64 sequence bounds" do
    assert {:ok, key, request, _} = PlayerPlacementIntent.request(@source, 1, intent())

    request = %{
      request
      | expected: Map.put(request.expected, {1, 63, 1}, 1),
        sequence: 18_446_744_073_709_551_615
    }

    assert {:ok, bytes} = PlacementRequest.encode(key, request)
    assert byte_size(bytes) == 104
    assert {:ok, ^request} = PlacementRequest.decode(bytes, key)

    assert {:error, :invalid_placement_request} =
             PlacementRequest.encode(key, %{request | sequence: request.sequence + 1})

    <<header::binary-size(76), first::binary-size(14), last::binary-size(14)>> = bytes

    assert {:error, :invalid_placement_request} =
             PlacementRequest.decode(header <> first <> first, key)

    assert {:error, :invalid_placement_request} =
             PlacementRequest.decode(header <> last <> first, key)
  end
end
