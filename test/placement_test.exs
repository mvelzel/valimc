defmodule Valimc.PlacementTest do
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Placement
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
      refute Valimc.Living.Interaction.valid_hit?(decoded.position, decoded.cursor)
    end

    # Native booleans accept any nonzero byte; coordinate validity belongs to admission.
    odd = <<0, 0::64, 1, 5::float-32, 0.5::float-32, 0.5::float-32, 2, 255, 0>>
    assert {:ok, %{inside: true, border: true} = decoded} = UseItemOn.decode(odd)
    refute Valimc.Living.Interaction.valid_hit?(decoded.position, decoded.cursor)
  end

  test "a click replaces the clicked block only where vanilla's replacement says so" do
    target = fn item, clicked, request ->
      {:ok, %{position: position, replace_clicked: replace}} =
        Placement.target(item(item), clicked, Map.merge(%{yaw: 0.0, pitch: 0.0}, request))

      {position, replace}
    end

    slab = Valimc.Data.Blocks.state("oak_slab", %{"type" => "bottom"})
    candle = Valimc.Data.Blocks.default_state("candle")
    assert target.("stone", 0, request()) == {{0, 64, 0}, true}
    assert target.("stone", Data.block("stone"), request()) == {{0, 65, 0}, false}
    # A bottom slab yields to its own slab from above, not to another item.
    assert target.("oak_slab", slab, request()) == {{0, 64, 0}, true}
    assert target.("stone", slab, request()) == {{0, 65, 0}, false}
    assert target.("oak_slab", slab, request(2, 0.25)) == {{0, 64, -1}, false}
    # A candle takes another candle unless the player sneaks.
    assert target.("candle", candle, request()) == {{0, 64, 0}, true}
    assert target.("candle", candle, Map.put(request(), :secondary, true)) == {{0, 65, 0}, false}
    assert {:error, :invalid_context} = Placement.target(item("stone"), -1, request())
  end

  test "the click's inputs follow vanilla's view directions" do
    values = fn yaw, pitch ->
      Placement.values(Map.merge(request(), %{yaw: yaw, pitch: pitch}), false)
    end

    # Looking south and slightly down: horizontal south (0), vertical down.
    [_order, vertical, horizontal | _] = values.(0.0, 10.0)
    assert {vertical, horizontal} == {0, 0}
    # Looking west and up.
    [_order, vertical, horizontal | _] = values.(90.0, -30.0)
    assert {vertical, horizontal} == {1, 1}
    # The cursor at the middle of the clicked face's top edge, face up, not replacing.
    assert Enum.slice(values.(0.0, 0.0), 4..12) == [1 * 9 + 1 * 3 + 1, 0, 1, 0, 0, 0, 0, 0, 0]
    assert Placement.on_water?(item("lily_pad")) and not Placement.on_water?(item("oak_door"))
    assert Placement.placeable?(item("oak_door"))
  end
end
