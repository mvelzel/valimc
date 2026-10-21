defmodule Valimc.PlayerPlacementIntentTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerPlacementIntent
  alias Valimc.Protocol.ItemStack
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
end
