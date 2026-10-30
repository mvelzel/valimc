defmodule Valimc.WorldgenBackgroundTest do
  @moduledoc """
  The generation jobs' background twins (VMC-081c) give what their dirty
  NIFs give: the same terrain, decoration, encoding and full chunk (lit alone,
  as `light_column_image` lights it), and the same raise on bad input. A
  full chunk's column handle installs as its image and lights a neighbour's
  ring as the image lit there (VMC-081c2).
  """
  use ExUnit.Case, async: true
  alias Valimc.{Native, Worldgen}
  alias Valimc.World.Blocks

  @seed 20_261_020
  @source "minecraft:overworld"

  setup_all do
    {:ok, state} = Worldgen.new(@seed)
    %{state: state, biomes: Worldgen.Generator.protocol_biomes()}
  end

  defp terrain(state, {x, z}, background) do
    if background,
      do: Native.background(&Native.gen_terrain_background(&1, state, @source, nil, x, z)),
      else: Native.gen_terrain(state, @source, nil, x, z)
  end

  defp encoded(cell), do: elem(Native.gen_encode(cell), 1)

  test "terrain, decoration, encoding and full chunks match", %{state: state, biomes: biomes} do
    around = for dz <- -1..1, dx <- -1..1, do: {3 + dx, -7 + dz}

    [dirty, background] =
      for flag <- [false, true] do
        Enum.map(around, fn chunk ->
          {:ok, cell} = terrain(state, chunk, flag)
          cell
        end)
      end

    assert Enum.map(dirty, &encoded/1) == Enum.map(background, &encoded/1)

    assert {:ok, lenient} = Native.gen_decorate(state, @source, nil, {3, -7}, dirty)

    assert {:ok, ^lenient} =
             Native.background(
               &Native.gen_decorate_background(&1, state, @source, nil, {3, -7}, background)
             )

    centre = Enum.at(background, 4)
    bytes = encoded(Enum.at(dirty, 4))
    assert {:ok, ^bytes} = Native.background(&Native.gen_encode_background(&1, centre))
    assert {:ok, decoded} = Native.background(&Native.gen_decode_background(&1, state, bytes))
    assert encoded(decoded) == bytes

    {:ok, full} = Native.gen_full(state, Enum.at(dirty, 4), biomes)
    {:ok, lit} = Native.light_column_image(full.image, true)

    assert {:ok, %{full | image: lit}} ==
             Native.background(&Native.gen_full_background(&1, state, centre, biomes, true))
  end

  test "a failure raises as the dirty NIF does", %{state: state} do
    message =
      try do
        Native.gen_decode(state, <<1, 2, 3>>)
      rescue
        error -> Exception.message(error)
      end

    assert_raise ErlangError, message, fn ->
      Native.background(&Native.gen_decode_background(&1, state, <<1, 2, 3>>))
    end
  end

  test "a full chunk's column handle lights a neighbour's ring as its image lit there does",
       %{state: state, biomes: biomes} do
    chunk = {7, -7}
    around = for dz <- -1..1, dx <- -1..1, do: {7 + dx, -7 + dz}

    cells =
      Enum.map(around, fn chunk ->
        {:ok, cell} = terrain(state, chunk, false)
        cell
      end)

    {:ok, _} = Native.gen_decorate(state, @source, nil, {7, -7}, cells)
    {:ok, unlit} = Native.gen_full(state, Enum.at(cells, 4), biomes)

    {:ok, lit} =
      Native.background(&Native.gen_full_background(&1, state, Enum.at(cells, 4), biomes, true))

    spec = Blocks.packet_spec(:overworld)
    {:ok, handle} = Blocks.column_handle(lit.image, {:background, chunk, spec})
    assert {:error, :invalid_layers} = Blocks.column_handle(<<1, 2, 3>>)

    # Its own section installs it from the handle.
    own = Valimc.World.RegionGeneration.chunks_of({0, -1})
    {:ok, blocks} = Blocks.new({0, -1}, %{}, %{}, MapSet.new(own))
    {:ok, _} = Blocks.put_columns(blocks, %{chunk => handle})
    assert Blocks.column_image(blocks, chunk) == {:ok, unlit.image}

    # Its first packet is the job's, once; later ones encode as before.
    encoded = Blocks.encode(blocks, chunk)
    entities = Blocks.chunk_entities(blocks, chunk)
    assert Blocks.prepared(blocks, chunk) == {encoded, entities}
    assert Blocks.prepared(blocks, chunk) == nil

    # A chunk written after it was installed encodes anew.
    {:ok, again} = Blocks.new({0, -1}, %{}, %{}, MapSet.new(own))
    {:ok, _} = Blocks.put_columns(again, %{chunk => handle})
    :ok = Blocks.put(again, %{{7 * 16 + 3, 100, -7 * 16 + 3} => 1})
    assert Blocks.prepared(again, chunk) == nil

    # The east neighbour's ring: the handle with its light alone, or the
    # image lit there.
    east = Valimc.World.RegionGeneration.chunks_of({1, -1})

    [given, relit] =
      for sent <- [handle, unlit.image] do
        {:ok, ring} = Blocks.new({1, -1}, %{}, %{}, MapSet.new())
        {:ok, _} = Native.halo_put(ring.ref, [{7, -7, sent}])
        for chunk <- east, do: Blocks.light_image(ring, chunk)
      end

    assert given == relit
  end
end
