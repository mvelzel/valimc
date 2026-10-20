defmodule Valimc.WorldNbtTest do
  @moduledoc "Disk NBT framing, compression bounds and world schemas (VMC-020)."
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Valimc.NBT
  alias Valimc.World.Schema

  @root {:compound,
         %{
           "DataVersion" => {:int, 5023},
           "name" => {:string, "Ünïcødé 𝄞" <> <<0>>},
           "pos" => {:list, {:double, [<<1.5::float-64>>, <<-0.0::float-64>>]}},
           "data" => {:long_array, <<1::64, -1::signed-64>>},
           "mixed" => NBT.list([{:int, 1}, {:string, "two"}]),
           "nested" => {:compound, %{"empty" => {:list, {:end, []}}}}
         }}

  defp bytes(tag), do: IO.iodata_to_binary(NBT.write(tag))

  defp nest(depth),
    do: Enum.reduce(2..depth//1, {:compound, %{}}, &{:compound, %{"n#{&1}" => &2}})

  test "disk roots round trip, skip the root name and refuse other roots or trailing bytes" do
    assert {:ok, @root} = NBT.read(bytes(@root))
    <<10, 0::16, payload::binary>> = bytes(@root)
    assert {:ok, @root} = NBT.read(<<10, 4::16, "root", payload::binary>>)
    assert NBT.read(<<3, 0::16, 5::32>>) == {:error, :nbt_root_not_compound}
    assert NBT.read(<<0>>) == {:error, :nbt_root_not_compound}
    assert NBT.read(bytes(@root) <> <<0>>) == {:error, :trailing_nbt_bytes}
    assert_raise ArgumentError, fn -> NBT.write({:compound, %{"x" => {:byte, 300}}}) end
  end

  test "a repeated compound name replaces the earlier value on disk and is refused on the wire" do
    entries = <<3, 1::16, "a", 1::32, 3, 1::16, "a", 2::32, 0>>
    assert NBT.read(<<10, 0::16, entries::binary>>) == {:ok, {:compound, %{"a" => {:int, 2}}}}
    assert NBT.decode(<<10, entries::binary>>) == {:error, :duplicate_nbt_name}
  end

  # A root compound holding `depth - 1` nested lists.
  defp nest_lists(depth) do
    {:list, value} =
      Enum.reduce(3..depth//1, {:list, {:end, []}}, fn _, {:list, inner} ->
        {:list, {:list, [inner]}}
      end)

    {:compound, %{"l" => {:list, value}}}
  end

  test "disk depth counts compounds and lists like vanilla: 512 pass, 513 do not" do
    for nest <- [&nest/1, &nest_lists/1] do
      assert {:ok, _} = NBT.read(bytes(nest.(512)))
      assert_raise ArgumentError, fn -> NBT.write(nest.(513)) end
      raw = IO.iodata_to_binary(NBT.write(nest.(513), %{NBT.disk_limits() | depth: 513}))
      assert NBT.read(raw) == {:error, :nbt_depth_limit}
    end
  end

  test "byte and node limits are explicit per call" do
    raw = bytes(@root)

    assert NBT.read(raw, %{NBT.disk_limits() | bytes: byte_size(raw) - 1}) ==
             {:error, :nbt_byte_limit}

    assert NBT.read(raw, %{NBT.disk_limits() | nodes: 5}) == {:error, :nbt_node_limit}
  end

  test "gzip, zlib and stored framing round trip; inflation is bounded and checked" do
    for compression <- [:gzip, :zlib, :none] do
      stored = NBT.write_compressed(@root, compression)
      assert NBT.read_compressed(stored, compression) == {:ok, @root}
    end

    # A small stream that inflates to 16 MiB stops at the limit.
    bomb = :zlib.compress(:binary.copy(<<0>>, 16 * 1024 * 1024))
    assert byte_size(bomb) < 32_768
    assert NBT.decompress(bomb, :zlib, 1024 * 1024) == {:error, :nbt_byte_limit}
    assert NBT.decompress(<<1, 2, 3>>, :none, 2) == {:error, :nbt_byte_limit}

    zlib = NBT.write_compressed(@root, :zlib)

    assert NBT.decompress(binary_part(zlib, 0, 10), :zlib, 1_048_576) ==
             {:error, :truncated_compression}

    assert NBT.decompress(<<0, 1, 2, 3, 4>>, :zlib, 1024) == {:error, :invalid_compression}
    assert NBT.decompress(zlib, :gzip, 1024) == {:error, :invalid_compression}
  end

  property "mutated, truncated or extended disk files are refused or read, never raise" do
    raw = bytes(@root)

    check all(
            flips <- list_of({integer(0..(byte_size(raw) - 1)), integer(0..255)}, max_length: 4),
            cut <- integer(0..byte_size(raw)),
            tail <- binary(max_length: 8)
          ) do
      mutated =
        Enum.reduce(flips, raw, fn {at, byte}, acc ->
          <<head::binary-size(^at), _, rest::binary>> = acc
          <<head::binary, byte, rest::binary>>
        end)

      candidate = binary_part(mutated, 0, cut) <> tail

      case NBT.read(candidate) do
        {:ok, {:compound, _}} -> :ok
        {:error, reason} -> assert is_atom(reason)
      end

      case NBT.decompress(candidate, :zlib, 65_536) do
        {:ok, out} -> assert byte_size(out) <= 65_536
        {:error, reason} -> assert is_atom(reason)
      end
    end
  end

  test "world files are classified by path and accepted only at the pinned data version" do
    assert Schema.kind("level.dat") == :level
    assert Schema.kind("players/data/0f3a.dat") == :player
    assert Schema.kind("data/minecraft/scoreboard.dat") == :data
    assert Schema.kind("dimensions/minecraft/the_end/data/minecraft/raids.dat") == :data
    assert Schema.kind("dimensions/minecraft/overworld/region/r.0.-1.mca") == :chunk
    assert Schema.kind("dimensions/minecraft/overworld/entities/r.0.0.mca") == :entities
    assert Schema.kind("dimensions/minecraft/overworld/poi/r.0.0.mca") == :poi
    assert Schema.kind("session.lock") == :unknown

    version = Schema.data_version()
    level = fn v -> {:compound, %{"Data" => {:compound, %{"DataVersion" => {:int, v}}}}} end
    chunk = fn v -> {:compound, %{"DataVersion" => {:int, v}}} end
    assert Schema.check(:level, level.(version)) == {:ok, version}
    assert Schema.check(:chunk, chunk.(version)) == {:ok, version}
    assert Schema.check(:chunk, chunk.(3953)) == {:error, {:older_data_version, 3953}}

    assert Schema.check(:chunk, chunk.(version + 1)) ==
             {:error, {:newer_data_version, version + 1}}

    assert Schema.check(:level, chunk.(version)) == {:error, :missing_data_version}

    assert Schema.check(:chunk, {:compound, %{"DataVersion" => {:long, version}}}) ==
             {:error, :missing_data_version}

    assert Schema.check(:unknown, chunk.(version)) == {:error, :unknown_world_file}
  end
end
