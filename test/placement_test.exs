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

  test "slab side hit boundaries distinguish halves and merge into a dry double" do
    slab = item("oak_slab")
    assert {:ok, %{state: 15_180}} = Placement.candidate(slab, 0, 0, request(2, 0.5))

    assert {:ok, %{state: 15_178}} =
             Placement.candidate(slab, 0, 0, request(2, 0.5000000596046448))

    assert {:ok, %{state: 15_178}} = Placement.candidate(slab, 0, 0, request(0))
    assert {:ok, %{state: 15_180}} = Placement.candidate(slab, 0, 0, request(1, 1.0))

    assert {:ok, %{state: 15_182, replace_clicked: true}} =
             Placement.candidate(slab, 15_179, 0, request(1))

    assert {:ok, %{state: 15_182, replace_clicked: true}} =
             Placement.candidate(slab, 15_177, 0, request(2, 0.5))

    assert {:error, :occupied} = Placement.candidate(slab, 15_182, 1, request())

    assert {:ok, %{state: 15_182, position: {0, 65, 0}, replace_clicked: false}} =
             Placement.candidate(slab, 1, 15_177, request())

    assert {:error, :occupied} = Placement.candidate(item("stone_slab"), 1, 15_179, request())
  end

  test "only source water waterlogs a new slab; merging discards the contained source" do
    slab = item("oak_slab")
    assert {:ok, %{state: 15_179}} = Placement.candidate(slab, 89, 0, request())
    assert {:ok, %{state: 15_177}} = Placement.candidate(slab, 89, 0, request(0))
    assert {:ok, %{state: 15_180}} = Placement.candidate(slab, 90, 0, request())
    assert {:ok, %{state: 15_182}} = Placement.candidate(slab, 1, 15_179, request())
  end

  test "ordinary cube admission includes stone, wood, mineral storage and color families" do
    for name <- ~w(polished_granite spruce_planks iron_block red_concrete purple_terracotta) do
      assert Placement.supported_item?(item(name))
      assert {:ok, %{state: state}} = Placement.candidate(item(name), 0, 0, request())
      assert state == Data.item_block(item(name))
    end

    for name <- ~w(sand chest oak_stairs redstone_block) do
      refute Placement.supported_item?(item(name))
      assert {:error, :unsupported_item} = Placement.candidate(item(name), 0, 0, request())
    end
  end

  test "pillar axes follow every clicked face through liquid replacement and solid adjacency" do
    for {name, axes} <- [{"oak_log", {139, 140, 141}}, {"stripped_spruce_log", {177, 178, 179}}],
        {face, axis} <- [{0, 1}, {1, 1}, {2, 2}, {3, 2}, {4, 0}, {5, 0}] do
      assert Placement.supported_item?(item(name))
      state = elem(axes, axis)

      assert {:ok, %{state: ^state, position: {0, 64, 0}, replace_clicked: true}} =
               Placement.candidate(item(name), 89, 1, request(face))

      assert {:ok, %{state: ^state, replace_clicked: false}} =
               Placement.candidate(item(name), 1, 0, request(face))

      assert {:error, :occupied} = Placement.candidate(item(name), 1, 1, request(face))
    end
  end
end
