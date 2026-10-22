defmodule Valimc.PlacementTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.Placement
  alias Valimc.Protocol.{Data, ItemStack, UseItemOn, Wire}

  defp request(face \\ 1, y \\ 0.5),
    do: %{position: {0, 64, 0}, face: face, cursor: {0.5, y, 0.5}}

  defp item(name), do: ItemStack.new(name).item_id

  test "block-use decoding is bounded; nonfinite hits remain acknowledgeable without authority" do
    body =
      IO.iodata_to_binary([
        <<0>>,
        Wire.position({-33_554_432, -2048, 33_554_431}),
        <<5, 0.25::float-32, 0.5::float-32, 0.75::float-32, 0, 1, 127>>
      ])

    assert {:ok,
            %{
              position: {-33_554_432, -2048, 33_554_431},
              hand: :main,
              face: 5,
              sequence: 127,
              inside: false,
              border: true
            }} = UseItemOn.decode(body)

    for size <- 0..24 do
      assert {:error, :invalid_use_item_on} = UseItemOn.decode(binary_part(body, 0, size))
    end

    for malformed <- [
          body <> <<0>>,
          body <> :binary.copy(<<0>>, 13),
          <<2>> <> binary_part(body, 1, 24),
          binary_part(body, 0, 9) <> <<6>> <> binary_part(body, 10, 15),
          binary_part(body, 0, 24) <> Wire.varint(-1),
          binary_part(body, 0, 24) <> <<128, 128, 128, 128, 128, 0>>
        ] do
      assert {:error, :invalid_use_item_on} = UseItemOn.decode(malformed)
    end

    for bits <- [0x7FC00000, 0x7F800000, 0xFF800000] do
      raw = binary_part(body, 0, 10) <> <<bits::32>> <> binary_part(body, 14, 11)
      assert {:ok, %{cursor: :nonfinite, sequence: 127} = decoded} = UseItemOn.decode(raw)
      refute Valimc.PlayerInteraction.valid_hit?(decoded.position, decoded.cursor)
    end

    # Native booleans accept any nonzero byte; coordinate validity belongs to admission.
    odd = <<0, 0::64, 1, 5::float-32, 0.5::float-32, 0.5::float-32, 2, 255, 0>>
    assert {:ok, %{inside: true, border: true} = decoded} = UseItemOn.decode(odd)
    refute Valimc.PlayerInteraction.valid_hit?(decoded.position, decoded.cursor)
  end

  test "a creative ladder tries the directions the player looks along, clicked face first" do
    ladder = Valimc.Registry.Blocks.default_state("ladder")
    stone = Data.block("stone")
    facings = &for(s <- &1, do: Map.new(Valimc.Registry.Blocks.properties(s))["facing"])

    # On a floor while looking west (`Direction.orderedByNearest`): the wall
    # looked at first.
    floor = Map.merge(request(1), %{yaw: 90.0, pitch: 0.0})

    assert facings.(Placement.creative_states(ladder, stone, 0, floor)) ==
             ~w(east south north west)

    # On a wall's east face while looking down: that wall first, then the look.
    wall = Map.merge(request(5), %{yaw: 0.0, pitch: 80.0})
    assert hd(facings.(Placement.creative_states(ladder, stone, 0, wall))) == "east"

    # On the front of a ladder: nothing, as `LadderBlock` refuses it.
    front = Valimc.Registry.Blocks.state("ladder", %{"facing" => "east"})
    assert Placement.creative_states(ladder, front, 0, wall) == []
    assert Placement.creative_states(stone, stone, 0, wall) == [stone]
  end

  test "replaceable clicked cells win over the adjacent cell, but solids require free adjacency" do
    stone = item("stone")

    assert {:ok, %{position: {0, 64, 0}, state: 1, replace_clicked: true}} =
             Placement.candidate(stone, 0, 1, request())

    assert {:ok, %{position: {0, 65, 0}, state: 1, replace_clicked: false}} =
             Placement.candidate(stone, 1, 0, request())

    assert {:error, :occupied} = Placement.candidate(stone, 1, 1, request())

    assert {:error, :unsupported_replacement} =
             Placement.candidate(stone, Data.item_block(item("candle")), 0, request())

    assert {:error, :unsupported_item} = Placement.candidate(item("grass_block"), 1, 0, request())
    assert {:error, :invalid_context} = Placement.candidate(stone, -1, 0, request())
    assert {:error, :invalid_context} = Placement.candidate(stone, 0, 0, request(6))
  end
end
