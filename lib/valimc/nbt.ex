defmodule Valimc.NBT do
  @moduledoc """
  Bounded NBT for the network and for world files (VMC-020).

  A tag is `{type, value}`: integers as integers, floats and dense arrays as their
  big-endian bytes, strings as UTF-8, lists as `{element_type, values}` and
  compounds as maps of name => tag.

  Every read and write runs under explicit limits (`t:limits/0`): encoded bytes,
  nodes, nested containers (compounds and lists, as vanilla's `NbtAccounter`
  counts them) and what a repeated compound name does. The network framing
  (unnamed root) keeps the protocol budget and refuses repeated names. The disk
  framing (`read/2`, `write/2`) reads a named compound root whose name it skips
  and writes the name `""`, like vanilla's `NbtIo`; it allows vanilla's 512
  containers and lets a repeated name replace the earlier value, as vanilla's
  `CompoundTag` does. `decompress/3` inflates gzip or zlib under a byte limit.

  Divergence: Java's modified UTF-8 admits unpaired surrogates; ValiMC refuses
  them (`:invalid_nbt_utf`) because they have no UTF-8 form.
  """
  import Bitwise
  alias Valimc.Native

  @types %{
    0 => :end,
    1 => :byte,
    2 => :short,
    3 => :int,
    4 => :long,
    5 => :float,
    6 => :double,
    7 => :byte_array,
    8 => :string,
    9 => :list,
    10 => :compound,
    11 => :int_array,
    12 => :long_array
  }
  @ids Map.new(@types, fn {id, type} -> {type, id} end)
  @names List.to_tuple(for id <- 0..12, do: @types[id])
  @four_byte_prefixes [<<0xF0>>, <<0xF1>>, <<0xF2>>, <<0xF3>>, <<0xF4>>]

  @typedoc """
  `bytes`: encoded (inflated) bytes; `nodes`: tags; `depth`: nested compounds and
  lists, the root included; `duplicates`: `:refuse` or `:replace`.
  """
  @type limits :: %{
          bytes: pos_integer(),
          nodes: pos_integer(),
          depth: pos_integer(),
          duplicates: :refuse | :replace
        }
  @type tag :: {atom(), term()}

  # Protocol budgets: 32 (64) levels below the root container.
  @network %{bytes: 65_536, nodes: 1024, depth: 33, duplicates: :refuse}
  @server_component %{bytes: 262_144, nodes: 8192, depth: 65, duplicates: :refuse}
  # Vanilla reads region chunks without a quota; these bound memory instead.
  @disk %{bytes: 64 * 1024 * 1024, nodes: 2_000_000, depth: 512, duplicates: :replace}

  @doc "Network limits (inbound item/text data)."
  def network_limits, do: @network

  @doc "World-file limits: vanilla's 512 containers; explicit byte and node bounds."
  def disk_limits, do: @disk

  ## Network framing: unnamed root

  def take(bytes, limits \\ @network) when is_binary(bytes) do
    options = options(limits, true)

    case bytes do
      <<0, rest::binary>> ->
        {:ok, {:end, nil}, rest}

      <<id, rest::binary>> ->
        {value, rest, _} = value(id, rest, limits.nodes - 1, 0, options)
        check(byte_size(bytes) - byte_size(rest) <= limits.bytes, :nbt_byte_limit)
        {:ok, {elem(@names, id), value}, rest}

      <<>> ->
        throw({:nbt_error, :truncated_nbt})
    end
  rescue
    ArgumentError -> {:error, :malformed_nbt}
    MatchError -> {:error, :malformed_nbt}
    FunctionClauseError -> {:error, :malformed_nbt}
  catch
    {:nbt_error, reason} -> {:error, reason}
  end

  def decode(bytes, limits \\ @network) do
    case take(bytes, limits) do
      {:ok, tag, <<>>} -> {:ok, tag}
      {:ok, _, _} -> {:error, :trailing_nbt_bytes}
      error -> error
    end
  end

  def encode(tag, limits \\ @network) do
    {type, value} = tag
    id = @ids[type]
    check(id != nil, :unknown_nbt_tag)
    {payload, _} = write_value(id, value, limits.nodes - 1, 0, limits.depth)
    bytes = [id, payload]
    check(IO.iodata_length(bytes) <= limits.bytes, :nbt_byte_limit)
    bytes
  end

  @doc "Bounded outbound composition of admitted item/text data; never an input decoder."
  def encode_server_component(tag), do: encode(tag, @server_component)

  def valid?(tag) do
    encode(tag)
    true
  rescue
    _ -> false
  catch
    {:nbt_error, _} -> false
  end

  ## Disk framing: named compound root

  # Up to this size the native reader stays well under 1 ms on a normal scheduler.
  @dirty_bytes 131_072

  @doc """
  Read an uncompressed world-file root: a compound with a (skipped) name and no
  trailing bytes. With vanilla's duplicate rule the native reader
  (`valimc_core::nbt`) parses it; `read_reference/2` is the Elixir reader with
  the same results, used for the other rule and as the parity reference.
  """
  def read(bytes, limits \\ @disk)

  def read(bytes, %{duplicates: :replace} = limits) when is_binary(bytes) do
    read =
      if byte_size(bytes) > @dirty_bytes, do: &Native.nbt_read_dirty/4, else: &Native.nbt_read/4

    read.(bytes, limits.bytes, limits.nodes, limits.depth)
  end

  def read(bytes, limits) when is_binary(bytes), do: read_reference(bytes, limits)

  @doc false
  def read_reference(bytes, limits \\ @disk) when is_binary(bytes) do
    check(byte_size(bytes) <= limits.bytes, :nbt_byte_limit)
    options = options(limits, false)

    case bytes do
      <<10, size::16, _name::binary-size(size), rest::binary>> ->
        {value, rest, _} = value(10, rest, limits.nodes - 1, 0, options)
        check(rest == <<>>, :trailing_nbt_bytes)
        {:ok, {:compound, value}}

      <<10, _::binary>> ->
        throw({:nbt_error, :truncated_nbt})

      _ ->
        throw({:nbt_error, :nbt_root_not_compound})
    end
  rescue
    ArgumentError -> {:error, :malformed_nbt}
    MatchError -> {:error, :malformed_nbt}
    FunctionClauseError -> {:error, :malformed_nbt}
  catch
    {:nbt_error, reason} -> {:error, reason}
  end

  @doc "Write a world-file root (compound named `\"\"`); raises on an invalid tag."
  def write({:compound, value}, limits \\ @disk) do
    {payload, _} = write_value(10, value, limits.nodes - 1, 0, limits.depth)
    bytes = [<<10, 0::16>>, payload]
    check(IO.iodata_length(bytes) <= limits.bytes, :nbt_byte_limit)
    bytes
  catch
    {:nbt_error, reason} -> raise ArgumentError, "invalid NBT: #{reason}"
  end

  @doc "Inflate and read a stored world file (`:gzip`, `:zlib` or `:none`)."
  def read_compressed(bytes, compression, limits \\ @disk) do
    with {:ok, raw} <- decompress(bytes, compression, limits.bytes), do: read(raw, limits)
  end

  @doc "Write and compress a world file."
  def write_compressed(tag, compression, limits \\ @disk),
    do: compress(write(tag, limits), compression)

  @doc """
  Inflate `bytes` without producing more than `max` bytes. A stream that ends
  early, is corrupt, or would exceed `max` is refused.
  """
  def decompress(bytes, :none, max) when is_binary(bytes),
    do: if(byte_size(bytes) <= max, do: {:ok, bytes}, else: {:error, :nbt_byte_limit})

  def decompress(bytes, compression, max)
      when compression in [:gzip, :zlib] and is_binary(bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, if(compression == :gzip, do: 31, else: 15))
      inflate(z, :zlib.safeInflate(z, bytes), [], 0, max)
    rescue
      ErlangError -> {:error, :invalid_compression}
    after
      :zlib.close(z)
    end
  end

  # `safeInflate` yields bounded output chunks and `:finished` once the input is
  # consumed; `inflateEnd` then raises unless the stream itself ended.
  defp inflate(z, {state, output}, acc, size, max) do
    chunk = IO.iodata_to_binary(output)
    size = size + byte_size(chunk)

    cond do
      size > max -> {:error, :nbt_byte_limit}
      state == :finished -> finish(z, [acc | chunk])
      chunk == <<>> -> {:error, :truncated_compression}
      true -> inflate(z, :zlib.safeInflate(z, []), [acc | chunk], size, max)
    end
  end

  defp finish(z, output) do
    :zlib.inflateEnd(z)
    {:ok, IO.iodata_to_binary(output)}
  rescue
    ErlangError -> {:error, :truncated_compression}
  end

  @doc "Compress `iodata` for storage."
  def compress(iodata, :none), do: IO.iodata_to_binary(iodata)
  def compress(iodata, :gzip), do: :zlib.gzip(iodata)
  def compress(iodata, :zlib), do: :zlib.compress(iodata)

  ## Tag helpers

  def float(value), do: {:float, <<value::float-32>>}
  def double(value), do: {:double, <<value::float-64>>}

  @doc "Typed sequence with native empty-name wrappers for mixed primitive/compound entries."
  def list([]), do: {:list, {:end, []}}

  def list(tags) do
    case Enum.uniq(Enum.map(tags, &elem(&1, 0))) do
      [type] ->
        {:list, {type, Enum.map(tags, &elem(&1, 1))}}

      _ ->
        {:list,
         {:compound,
          Enum.map(tags, fn
            {:compound, fields} -> fields
            tag -> %{"" => tag}
          end)}}
    end
  end

  @doc "Typed NBT comparison bytes: Mojang NaN equality, cached numeric zero and empty-list equality."
  def identity_key({type, value} = tag) do
    # Enforce the byte/node/depth budget before recursively visiting an input tree.
    encode(tag)
    encode({type, identity_value(type, value)}) |> IO.iodata_to_binary()
  end

  defp identity_value(:float, <<_sign::1, 255::8, mantissa::23>>) when mantissa != 0,
    do: <<0x7FC00000::32>>

  defp identity_value(:double, <<_sign::1, 2047::11, mantissa::52>>) when mantissa != 0,
    do: <<0x7FF8000000000000::64>>

  defp identity_value(:float, <<_sign::1, 0::31>>), do: <<0::32>>
  defp identity_value(:double, <<_sign::1, 0::63>>), do: <<0::64>>

  defp identity_value(:compound, values),
    do:
      Map.new(values, fn {name, {type, value}} -> {name, {type, identity_value(type, value)}} end)

  defp identity_value(:list, {_type, []}), do: {:end, []}

  defp identity_value(:list, {type, values}),
    do: {type, Enum.map(values, &identity_value(type, &1))}

  defp identity_value(_, value), do: value

  ## Reading

  # Reading threads the nodes left; `options` is {containers, duplicate rule,
  # copy small values?, byte limit}. A reader cannot consume more bytes than it
  # is given, so the byte limit is checked on the input (or what `take` consumed)
  # and on array lengths before they are sliced.
  defp options(%{bytes: bytes, depth: depth, duplicates: duplicates}, retain)
       when duplicates in [:refuse, :replace],
       do: {depth, duplicates, retain, bytes}

  defp value(1, <<v::signed-8, r::binary>>, n, _, _), do: {v, r, n}
  defp value(2, <<v::signed-16, r::binary>>, n, _, _), do: {v, r, n}
  defp value(3, <<v::signed-32, r::binary>>, n, _, _), do: {v, r, n}
  defp value(4, <<v::signed-64, r::binary>>, n, _, _), do: {v, r, n}
  defp value(5, <<v::binary-4, r::binary>>, n, _, o), do: {keep(v, o), r, n}
  defp value(6, <<v::binary-8, r::binary>>, n, _, o), do: {keep(v, o), r, n}
  defp value(7, <<c::signed-32, r::binary>>, n, _, o), do: array(c, 1, r, n, o)
  defp value(11, <<c::signed-32, r::binary>>, n, _, o), do: array(c, 4, r, n, o)
  defp value(12, <<c::signed-32, r::binary>>, n, _, o), do: array(c, 8, r, n, o)

  defp value(8, bytes, n, _, o) do
    {v, r} = string(bytes, o)
    {v, r, n}
  end

  defp value(9, <<id, c::signed-32, r::binary>>, n, d, o) do
    d = enter(o, d)
    check(id <= 12, :unknown_nbt_tag)
    check(c >= 0, :invalid_nbt_list)
    check(id != 0 or c == 0, :invalid_nbt_list)
    n = n - c
    check(n >= 0, :nbt_node_limit)
    {values, r, n} = elements(id, c, r, n, d, o, [])
    {{elem(@names, id), values}, r, n}
  end

  defp value(10, bytes, n, d, o), do: entries(bytes, n, enter(o, d), o, %{})
  defp value(0, r, n, _, _), do: {nil, r, n}
  defp value(id, _, _, _, _) when id in 1..12, do: throw({:nbt_error, :truncated_nbt})
  defp value(_, _, _, _, _), do: throw({:nbt_error, :unknown_nbt_tag})

  defp array(count, width, bytes, n, {_, _, _, limit} = o) do
    check(count >= 0, :invalid_nbt_array_length)
    size = count * width
    check(size <= limit, :nbt_byte_limit)

    case bytes do
      <<v::binary-size(^size), r::binary>> -> {keep(v, o), r, n}
      _ -> throw({:nbt_error, :truncated_nbt})
    end
  end

  defp elements(_, 0, r, n, _, _, acc), do: {:lists.reverse(acc), r, n}

  defp elements(id, c, r, n, d, o, acc) do
    {v, r, n} = value(id, r, n, d, o)
    elements(id, c - 1, r, n, d, o, [v | acc])
  end

  defp entries(<<0, r::binary>>, n, _, _, acc), do: {acc, r, n}

  defp entries(<<id, bytes::binary>>, n, d, {_, duplicates, _, _} = o, acc) do
    check(id <= 12, :unknown_nbt_tag)
    {name, r} = string(bytes, o)
    check(duplicates == :replace or not is_map_key(acc, name), :duplicate_nbt_name)
    n = n - 1
    check(n >= 0, :nbt_node_limit)
    {v, r, n} = value(id, r, n, d, o)
    entries(r, n, d, o, Map.put(acc, name, {elem(@names, id), v}))
  end

  defp entries(<<>>, _, _, _, _), do: throw({:nbt_error, :truncated_nbt})

  defp string(<<size::16, raw::binary-size(size), r::binary>>, o) do
    value = if ascii?(raw), do: raw, else: unicode(raw)
    {keep(value, o), r}
  end

  defp string(_, _), do: throw({:nbt_error, :truncated_nbt})

  defp ascii?(<<c, rest::binary>>) when c in 1..127, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_), do: false

  # Modified UTF-8 matches UTF-8 except for NUL (C0 80) and surrogate pairs, and
  # has no four-byte sequences.
  defp unicode(raw) do
    if String.valid?(raw) and :binary.match(raw, @four_byte_prefixes) == :nomatch,
      do: raw,
      else: decode_modified(raw)
  end

  # Network values must not pin a large packet; disk trees keep their slices.
  defp keep(bytes, {_, _, true, _}) do
    if :binary.referenced_byte_size(bytes) > 65_536, do: :binary.copy(bytes), else: bytes
  end

  defp keep(bytes, _), do: bytes

  ## Writing

  # Writing threads the nodes left and checks the container limit; the caller
  # checks the byte limit once on the result.
  defp write_value(1, v, n, _, _) when v in -128..127, do: {<<v::signed-8>>, n}
  defp write_value(2, v, n, _, _) when v in -32_768..32_767, do: {<<v::signed-16>>, n}

  defp write_value(3, v, n, _, _) when v in -2_147_483_648..2_147_483_647,
    do: {<<v::signed-32>>, n}

  defp write_value(4, v, n, _, _)
       when is_integer(v) and v >= -9_223_372_036_854_775_808 and
              v <= 9_223_372_036_854_775_807,
       do: {<<v::signed-64>>, n}

  defp write_value(5, v, n, _, _) when byte_size(v) == 4, do: {v, n}
  defp write_value(6, v, n, _, _) when byte_size(v) == 8, do: {v, n}
  defp write_value(7, v, n, _, _) when is_binary(v), do: {[<<byte_size(v)::32>>, v], n}

  defp write_value(11, v, n, _, _) when is_binary(v) and rem(byte_size(v), 4) == 0,
    do: {[<<div(byte_size(v), 4)::32>>, v], n}

  defp write_value(12, v, n, _, _) when is_binary(v) and rem(byte_size(v), 8) == 0,
    do: {[<<div(byte_size(v), 8)::32>>, v], n}

  defp write_value(8, v, n, _, _), do: {write_string(v), n}
  defp write_value(0, nil, n, _, _), do: {[], n}

  defp write_value(9, {type, values}, n, d, limit) when is_list(values) do
    check(d < limit, :nbt_depth_limit)
    id = @ids[type]
    count = length(values)
    check(id != nil and (id != 0 or count == 0), :invalid_nbt_list)
    n = n - count
    check(n >= 0, :nbt_node_limit)
    {parts, n} = write_elements(values, id, n, d + 1, limit, [])
    {[<<id, count::32>> | parts], n}
  end

  defp write_value(10, fields, n, d, limit) when is_map(fields) do
    check(d < limit, :nbt_depth_limit)
    n = n - map_size(fields)
    check(n >= 0, :nbt_node_limit)
    write_fields(:lists.keysort(1, :maps.to_list(fields)), n, d + 1, limit, [])
  end

  defp write_value(id, _, _, _, _) when id in 0..12, do: throw({:nbt_error, :invalid_nbt_value})

  defp write_elements([], _, n, _, _, acc), do: {:lists.reverse(acc), n}

  defp write_elements([v | rest], id, n, d, limit, acc) do
    {part, n} = write_value(id, v, n, d, limit)
    write_elements(rest, id, n, d, limit, [part | acc])
  end

  defp write_fields([], n, _, _, acc), do: {:lists.reverse(acc, [0]), n}

  defp write_fields([{name, {type, v}} | rest], n, d, limit, acc) do
    id = @ids[type]
    check(id != nil and id != 0, :invalid_nbt_value)
    {part, n} = write_value(id, v, n, d, limit)
    write_fields(rest, n, d, limit, [[id, write_string(name), part] | acc])
  end

  defp write_fields(_, _, _, _, _), do: throw({:nbt_error, :invalid_nbt_value})

  defp write_string(value) when is_binary(value) and byte_size(value) <= 65_535 do
    raw =
      cond do
        ascii?(value) -> value
        not String.valid?(value) -> throw({:nbt_error, :invalid_nbt_utf})
        :binary.match(value, [<<0>> | @four_byte_prefixes]) == :nomatch -> value
        true -> encode_modified(value)
      end

    check(byte_size(raw) <= 65_535, :invalid_nbt_string_length)
    [<<byte_size(raw)::16>>, raw]
  end

  defp write_string(value) when is_binary(value),
    do: throw({:nbt_error, :invalid_nbt_string_length})

  defp write_string(_), do: throw({:nbt_error, :invalid_nbt_utf})

  ## Modified UTF-8

  defp encode_modified(value) do
    utf16 = :unicode.characters_to_binary(value, :utf8, {:utf16, :big})

    for <<unit::16 <- utf16>>, into: <<>> do
      cond do
        unit in 1..127 -> <<unit>>
        unit <= 2047 -> <<0xC0 ||| unit >>> 6, 0x80 ||| (unit &&& 63)>>
        true -> <<0xE0 ||| unit >>> 12, 0x80 ||| (unit >>> 6 &&& 63), 0x80 ||| (unit &&& 63)>>
      end
    end
  end

  defp decode_modified(bytes) do
    utf16 = bytes |> units([]) |> Enum.reverse() |> IO.iodata_to_binary()
    value = :unicode.characters_to_binary(utf16, {:utf16, :big}, :utf8)
    check(is_binary(value), :invalid_nbt_utf)
    value
  end

  defp units(<<>>, units), do: units

  defp units(<<byte, rest::binary>>, units) when byte < 128,
    do: units(rest, [<<byte::16>> | units])

  defp units(<<first, second, rest::binary>>, units)
       when first in 0xC0..0xDF and (second &&& 0xC0) == 0x80,
       do: units(rest, [<<(first &&& 31) <<< 6 ||| (second &&& 63)::16>> | units])

  defp units(<<first, second, third, rest::binary>>, units)
       when first in 0xE0..0xEF and (second &&& 0xC0) == 0x80 and (third &&& 0xC0) == 0x80,
       do:
         units(rest, [
           <<(first &&& 15) <<< 12 ||| (second &&& 63) <<< 6 ||| (third &&& 63)::16>> | units
         ])

  defp units(_, _), do: throw({:nbt_error, :invalid_nbt_utf})

  ## Budget

  # Entering a compound or list: vanilla's `pushDepth` refuses the container
  # past the limit (512 on disk), counting the root.
  defp enter({limit, _, _, _}, depth) do
    check(depth < limit, :nbt_depth_limit)
    depth + 1
  end

  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:nbt_error, reason})
end
