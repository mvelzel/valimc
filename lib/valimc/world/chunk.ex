defmodule Valimc.World.Chunk do
  @moduledoc "Deterministic flat terrain and 26.3 paletted sections; sparse persisted edits."
  import Bitwise
  alias Valimc.Protocol.{Data, Packets, Wire}
  @min_y -64
  @max_y 319
  @air_states [0, 18_649, 18_650]
  def min_y, do: @min_y
  def max_y, do: @max_y
  def valid_y?(y), do: y >= @min_y and y <= @max_y

  def base(y) do
    cond do
      not valid_y?(y) -> Data.block("air")
      y == -64 -> Data.block("bedrock")
      y < 60 -> Data.block("stone")
      y < 63 -> Data.block("dirt")
      y == 63 -> Data.block("grass_block")
      true -> Data.block("air")
    end
  end

  def block_at(edits, {_, y, _} = position),
    do: if(valid_y?(y), do: Map.get(edits, position, base(y)), else: Data.block("air"))

  def load! do
    {_id, payload} = encode_full({0, 0}, %{})
    <<_coordinates::binary-size(8), tail::binary>> = IO.iodata_to_binary(payload)
    :persistent_term.put({__MODULE__, :flat_tail}, tail)
  end

  def encode({cx, cz}, edits) when map_size(edits) == 0 do
    Packets.packet("level_chunk_with_light", [
      <<cx::signed-32, cz::signed-32>>,
      :persistent_term.get({__MODULE__, :flat_tail})
    ])
  end

  def encode(key, edits), do: encode_full(key, edits)

  defp encode_full({cx, cz} = key, edits) do
    sections =
      for sy <- -4..19 do
        relevant =
          Map.filter(edits, fn {{x, y, z}, _} ->
            Integer.floor_div(x, 16) == cx and Integer.floor_div(z, 16) == cz and
              Integer.floor_div(y, 16) == sy
          end)

        section(cx, cz, sy, relevant)
      end

    index = Valimc.World.ColumnIndex.restore(edits, &block_at(edits, &1))

    columns =
      for z <- 0..15, x <- 0..15 do
        Valimc.World.ColumnIndex.heights(index, {cx * 16 + x, cz * 16 + z})
      end

    packet(
      %{
        chunk: key,
        sections: IO.iodata_to_binary(sections),
        surface: longs(Enum.map(columns, &(&1.world_surface - @min_y)), 9),
        motion: longs(Enum.map(columns, &(&1.motion_blocking - @min_y)), 9)
      },
      edits
    )
  end

  @doc "A chunk packet from encoded sections/heightmaps; `edits` supplies block entities."
  def packet(%{chunk: {cx, cz} = key, sections: data, surface: surface, motion: motion}, edits) do
    full_mask = (1 <<< 26) - 1
    light = :binary.copy(<<255>>, 2048)

    Packets.packet("level_chunk_with_light", [
      <<cx::signed-32, cz::signed-32>>,
      <<2, 1>>,
      Wire.varint(longs_count(surface)),
      surface,
      <<4>>,
      Wire.varint(longs_count(motion)),
      motion,
      Wire.varint(IO.iodata_length(data)),
      data,
      Valimc.Protocol.ChestBlockEntity.chunk_entries(key, edits),
      <<4, full_mask::little-32, 0, 0, 4, full_mask::little-32>>,
      <<26>>,
      List.duplicate([Wire.varint(2048), light], 26),
      <<0>>
    ])
  end

  defp longs_count(longs), do: div(IO.iodata_length(longs), 8)

  def section(cx, cz, sy, edits) do
    # All sections except the edited sections have a single block palette.
    values =
      if map_size(edits) == 0 do
        List.duplicate(base(sy * 16), 4096)
        |> maybe_surface(sy)
      else
        for y <- 0..15,
            z <- 0..15,
            x <- 0..15,
            do: block_at(edits, {cx * 16 + x, sy * 16 + y, cz * 16 + z})
      end

    # Vanilla counts non-air states (air, cave air, void air) and fluid-bearing states.
    count = Enum.count(values, &(&1 not in @air_states))
    fluids = Enum.count(values, &fluid?/1)
    biome = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
    [<<count::16, fluids::16>>, palette(values), <<0>>, Wire.varint(biome)]
  end

  defp maybe_surface(values, 3) do
    Enum.map(Enum.with_index(values), fn {_, index} -> base(48 + div(index, 256)) end)
  end

  defp maybe_surface(values, -4) do
    Enum.map(Enum.with_index(values), fn {_, index} -> base(-64 + div(index, 256)) end)
  end

  defp maybe_surface(values, _), do: values

  defp fluid?(block) do
    {:ok, %{kind: kind}} = Valimc.Physics.FluidBlocks.fetch(block)
    kind != :empty
  end

  def palette(values) do
    unique = Enum.uniq(values)

    if length(unique) == 1 do
      [<<0>>, Wire.varint(hd(unique))]
    else
      bits = max(4, ceil(:math.log2(length(unique))))

      if bits <= 8 do
        index = Map.new(Enum.with_index(unique))

        [
          <<bits>>,
          Wire.varint(length(unique)),
          Enum.map(unique, &Wire.varint/1),
          longs(Enum.map(values, &Map.fetch!(index, &1)), bits)
        ]
      else
        bits = Data.global_block_bits()
        [<<bits>>, longs(values, bits)]
      end
    end
  end

  def longs(values, bits) do
    per_long = div(64, bits)

    values
    |> Enum.chunk_every(per_long)
    |> Enum.map(fn entries ->
      value =
        entries
        |> Enum.with_index()
        |> Enum.reduce(0, fn {v, i}, acc -> acc ||| v <<< (i * bits) end)

      <<value::64>>
    end)
  end
end
