defmodule Valimc.World.ItemRecords do
  @moduledoc "Bounded stationary items and retry receipts; runtime handles are never persisted."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.World.Items
  @data_version 5023
  @max_count 256
  @item_bytes 524_288
  @max_sources 4096
  @max_bytes @item_bytes + 57 + @max_sources * 56
  def max_bytes, do: @max_bytes
  def max_sources, do: @max_sources

  def encode(key, records, receipts \\ %{})

  def encode({rx, rz}, records, receipts)
      when is_integer(rx) and is_integer(rz) and is_list(records) do
    check(rx in -2_147_483_648..2_147_483_647 and rz in -2_147_483_648..2_147_483_647)
    check(valid_receipts?(receipts))
    records = Enum.take(records, @max_count + 1)
    check(length(records) <= @max_count)
    check(length(Enum.uniq_by(records, fn %{uuid: uuid} -> uuid end)) == length(records))

    {parts, _} =
      Enum.map_reduce(records, 0, fn %{uuid: uuid, x: x, y: y, z: z, stack: stack}, size ->
        check(is_binary(uuid) and byte_size(uuid) == 16 and stack != nil)
        check(position_valid?({rx, rz}, {x, y, z}))
        check(stack.item_id != ItemTypes.id("air"))

        bytes = [
          <<uuid::binary-size(16), x::float-64, y::float-64, z::float-64>>,
          ItemStack.encode(stack)
        ]

        size = size + IO.iodata_length(bytes)
        check(size <= @item_bytes)
        {bytes, size}
      end)

    {version, receipt_body} =
      if map_size(receipts) == 0 do
        {1, []}
      else
        {2,
         [
           <<map_size(receipts)::16>>,
           receipts
           |> Enum.sort_by(&elem(&1, 0))
           |> Enum.map(fn {source, %{sequence: sequence, digest: digest}} ->
             <<source::binary-size(16), sequence::64, digest::binary-size(32)>>
           end)
         ]}
      end

    payload =
      IO.iodata_to_binary([
        <<"VMCITEMS", version, @data_version::32, rx::signed-32, rz::signed-32,
          length(records)::16>>,
        receipt_body,
        parts
      ])

    {:ok, payload <> :crypto.hash(:sha256, payload)}
  rescue
    _ -> {:error, :invalid_item_records}
  catch
    {:record_error, _} -> {:error, :invalid_item_records}
    {:item_error, _} -> {:error, :invalid_item_records}
  end

  def encode(_, _, _), do: {:error, :invalid_item_records}

  def decode(bytes, {rx, rz}) when is_binary(bytes) and byte_size(bytes) in 55..@max_bytes do
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), checksum::binary-size(32)>> = bytes
    check(:crypto.hash(:sha256, payload) == checksum)

    <<"VMCITEMS", version, @data_version::32, ^rx::signed-32, ^rz::signed-32, count::16,
      body::binary>> = payload

    check(count <= @max_count)

    {receipts, body} =
      case {version, body} do
        {1, body} ->
          {%{}, body}

        {2, <<sources::16, body::binary>>} ->
          check(sources <= @max_sources)
          take_receipts(body, sources, %{})
      end

    {records, <<>>} = take_records(body, count, [], MapSet.new(), {rx, rz})
    check(byte_size(body) <= @item_bytes)
    {:ok, %{records: Enum.reverse(records), receipts: receipts}}
  rescue
    _ -> {:error, :invalid_item_file}
  catch
    {:record_error, _} -> {:error, :invalid_item_file}
  end

  def decode(_, _), do: {:error, :invalid_item_file}

  def valid_receipts?(receipts) when is_map(receipts) and map_size(receipts) <= @max_sources do
    Enum.all?(receipts, fn
      {<<_::128>>, %{sequence: sequence, digest: <<_::256>>}} ->
        is_integer(sequence) and sequence in 1..18_446_744_073_709_551_615

      _ ->
        false
    end)
  end

  def valid_receipts?(_), do: false

  defp take_receipts(body, 0, receipts), do: {receipts, body}

  defp take_receipts(
         <<source::binary-size(16), sequence::64, digest::binary-size(32), body::binary>>,
         count,
         receipts
       ) do
    check(sequence > 0 and not Map.has_key?(receipts, source))

    take_receipts(
      body,
      count - 1,
      Map.put(receipts, source, %{sequence: sequence, digest: digest})
    )
  end

  defp take_records(body, 0, records, _, _key), do: {records, body}

  defp take_records(
         <<uuid::binary-size(16), x::float-64, y::float-64, z::float-64, body::binary>>,
         count,
         records,
         seen,
         key
       ) do
    check(not MapSet.member?(seen, uuid))
    check(position_valid?(key, {x, y, z}))
    {:ok, stack, rest} = ItemStack.take(body)
    check(stack != nil)
    record = %{uuid: uuid, x: x, y: y, z: z, stack: stack}
    take_records(rest, count - 1, [record | records], MapSet.put(seen, uuid), key)
  end

  defp position_valid?(key, {x, _, z} = position),
    do:
      Items.valid_position?(position) and
        Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp check(true), do: :ok
  defp check(false), do: throw({:record_error, :invalid})
end
