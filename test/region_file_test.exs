defmodule Valimc.RegionFileTest do
  @moduledoc "Anvil region file reading (VMC-021a); the oracle stage `region_files` checks vanilla's view."
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Valimc.Anvil.RegionFile
  alias Valimc.NBT
  import Bitwise

  @tag_bytes IO.iodata_to_binary(NBT.write({:compound, %{"DataVersion" => {:int, 5023}}}))

  # A region file with `chunks` = [{index, compression byte, payload}], one sector each.
  defp region(chunks) do
    {offsets, data} =
      chunks
      |> Enum.with_index(2)
      |> Enum.reduce({%{}, []}, fn {{index, type, payload}, sector}, {offsets, data} ->
        body = <<byte_size(payload) + 1::32, type, payload::binary>>
        padded = body <> :binary.copy(<<0>>, 4096 - rem(byte_size(body), 4096))
        {Map.put(offsets, index, <<sector::24, div(byte_size(padded), 4096)::8>>), [data, padded]}
      end)

    header = for i <- 0..1023, into: <<>>, do: Map.get(offsets, i, <<0::32>>)
    header <> :binary.copy(<<0>>, 4096) <> IO.iodata_to_binary(data)
  end

  defp read(bytes, dir \\ "/nonexistent", region \\ {0, 0}) do
    for {index, _, _, _} = slot <- RegionFile.slots(bytes),
        into: %{},
        do: {index, RegionFile.chunk(bytes, slot, {dir, region})}
  end

  test "file names give region coordinates, negative ones included" do
    assert RegionFile.coords("/w/region/r.-1.12.mca") == {:ok, {-1, 12}}
    assert RegionFile.coords("r.0.0.mcr") == :error
    assert RegionFile.chunk_pos({-1, 2}, 33) == {-31, 65}
  end

  test "each compression id reads; unknown ids are missing, custom ones an error" do
    bytes =
      region([
        {0, 1, :zlib.gzip(@tag_bytes)},
        {1, 2, :zlib.compress(@tag_bytes)},
        {2, 3, @tag_bytes},
        {3, 9, @tag_bytes},
        {4, 127, @tag_bytes}
      ])

    assert %{0 => {:ok, @tag_bytes}, 1 => {:ok, @tag_bytes}, 2 => {:ok, @tag_bytes}} = read(bytes)
    assert read(bytes)[3] == :absent
    assert read(bytes)[4] == {:error, :custom_compression}
  end

  @tag :tmp_dir
  test "external chunks come from c.X.Z.mcc next to the region file", %{tmp_dir: dir} do
    bytes = region([{33, 2 + 128, <<>>}])
    assert read(bytes, dir, {-1, 0}) == %{33 => :absent}
    File.write!(Path.join(dir, "c.-31.1.mcc"), :zlib.compress(@tag_bytes))
    assert read(bytes, dir, {-1, 0}) == %{33 => {:ok, @tag_bytes}}
  end

  test "header checks drop slots like vanilla; damaged chunk headers read as missing" do
    good = region([{0, 2, :zlib.compress(@tag_bytes)}])

    set = fn bytes, at, value ->
      <<binary_part(bytes, 0, at)::binary, value::binary,
        binary_part(bytes, at + byte_size(value), byte_size(bytes) - at - byte_size(value))::binary>>
    end

    assert RegionFile.slots(set.(good, 0, <<1::24, 1>>)) == []
    assert RegionFile.slots(set.(good, 0, <<2::24, 0>>)) == []
    assert RegionFile.slots(set.(good, 0, <<4::24, 1>>)) == []
    assert [{0, 3, 1, 0}] = RegionFile.slots(set.(good, 0, <<3::24, 1>>))
    assert read(set.(good, 0, <<3::24, 1>>)) == %{0 => :absent}
    assert RegionFile.slots(binary_part(good, 0, 2)) == []
    assert read(set.(good, 8192, <<0::32>>)) == %{0 => :absent}
    assert read(set.(good, 8192, <<-5::32>>)) == %{0 => :absent}
    assert read(set.(good, 8192, <<5000::32>>)) == %{0 => :absent}
    assert %{0 => {:error, _}} = read(set.(good, 8200, <<0xFF, 0xFF, 0xFF>>))
  end

  property "any bytes give slots and per-slot results without raising" do
    check all(bytes <- binary(max_length: 12_000)) do
      for {_, result} <- read(bytes) do
        assert result == :absent or match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  test "LZ4 block streams decode natively and are bounded" do
    plain = "abcabcabcabcabc!"
    lz = <<0x38, "abc", 3, 0, 0x10, "!">>
    checksum = 0x0FFFFFFF &&& xxh32(plain)

    block = fn token, data, original, sum ->
      <<"LZ4Block", token, byte_size(data)::little-32, byte_size(original)::little-32,
        sum::little-32, data::binary>>
    end

    stream = block.(0x26, lz, plain, checksum) <> block.(0x16, "", "", 0)
    assert NBT.decompress(stream, :lz4, 1024) == {:ok, plain}
    assert NBT.decompress(stream, :lz4, 8) == {:error, :nbt_byte_limit}

    assert NBT.decompress(binary_part(stream, 0, 30), :lz4, 1024) ==
             {:error, :truncated_compression}

    assert NBT.decompress(block.(0x26, lz, plain, checksum + 1), :lz4, 1024) ==
             {:error, :invalid_compression}
  end

  # Reference xxHash32 (seed 0x9747B28C, lz4-java's stream seed), for building test streams.
  defp xxh32(data) do
    seed = 0x9747B28C
    m = 0xFFFFFFFF
    [p1, p2, p3, p4, p5] = [2_654_435_761, 2_246_822_519, 3_266_489_917, 668_265_263, 374_761_393]
    rotl = fn x, r -> (x <<< r ||| x >>> (32 - r)) &&& m end
    round = fn acc, lane -> rotl.(acc + lane * p2 &&& m, 13) * p1 &&& m end

    {h, rest} =
      if byte_size(data) >= 16 do
        v = [seed + p1 + p2 &&& m, seed + p2 &&& m, seed, seed - p1 &&& m]

        {v, rest} =
          Stream.unfold(data, fn
            <<a::little-32, b::little-32, c::little-32, d::little-32, r::binary>> ->
              {[a, b, c, d], r}

            _ ->
              nil
          end)
          |> Enum.reduce({v, data}, fn lanes, {v, <<_::binary-16, r::binary>>} ->
            {Enum.zip_with(v, lanes, round), r}
          end)

        [a, b, c, d] = v
        {rotl.(a, 1) + rotl.(b, 7) + rotl.(c, 12) + rotl.(d, 18) &&& m, rest}
      else
        {seed + p5 &&& m, data}
      end

    h = h + byte_size(data) &&& m

    h =
      Stream.unfold(rest, fn
        <<lane::little-32, r::binary>> -> {{:word, lane}, r}
        <<byte, r::binary>> -> {{:byte, byte}, r}
        <<>> -> nil
      end)
      |> Enum.reduce(h, fn
        {:word, lane}, h -> rotl.(h + lane * p3 &&& m, 17) * p4 &&& m
        {:byte, byte}, h -> rotl.(h + byte * p5 &&& m, 11) * p1 &&& m
      end)

    h = (h ^^^ (h >>> 15)) * p2 &&& m
    h = (h ^^^ (h >>> 13)) * p3 &&& m
    h ^^^ (h >>> 16)
  end
end
