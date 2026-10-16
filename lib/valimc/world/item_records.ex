defmodule Valimc.World.ItemRecords do
  @moduledoc "Bounded items, optional motion and retry receipts; runtime handles are never persisted."
  import Bitwise
  alias Valimc.ItemMotionState
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
    moving = Enum.any?(records, &Map.has_key?(&1, :motion))

    {parts, _} =
      Enum.map_reduce(records, 0, fn %{uuid: uuid, x: x, y: y, z: z, stack: stack} = record,
                                     size ->
        check(is_binary(uuid) and byte_size(uuid) == 16 and stack != nil)
        check(position_valid?({rx, rz}, {x, y, z}))
        check(stack.item_id != ItemTypes.id("air"))

        bytes = [
          <<uuid::binary-size(16), x::float-64, y::float-64, z::float-64>>,
          encode_motion(record, moving),
          ItemStack.encode(stack)
        ]

        size = size + IO.iodata_length(bytes)
        check(size <= @item_bytes)
        {bytes, size}
      end)

    {version, receipt_body} =
      if not moving and map_size(receipts) == 0 do
        {1, []}
      else
        {if(moving, do: 3, else: 2),
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

        {version, <<sources::16, body::binary>>} when version in [2, 3] ->
          check(sources <= @max_sources)
          take_receipts(body, sources, %{})
      end

    {records, <<>>} = take_records(body, count, [], MapSet.new(), {rx, rz}, version)
    check(version != 3 or Enum.any?(records, &Map.has_key?(&1, :motion)))
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

  defp take_records(body, 0, records, _, _key, _version), do: {records, body}

  defp take_records(
         <<uuid::binary-size(16), x::float-64, y::float-64, z::float-64, body::binary>>,
         count,
         records,
         seen,
         key,
         version
       ) do
    check(not MapSet.member?(seen, uuid))
    check(position_valid?(key, {x, y, z}))
    {motion, body} = take_motion(body, version)
    {:ok, stack, rest} = ItemStack.take(body)
    check(stack != nil)
    record = %{uuid: uuid, x: x, y: y, z: z, stack: stack}
    record = if motion, do: Map.put(record, :motion, motion), else: record
    take_records(rest, count - 1, [record | records], MapSet.put(seen, uuid), key, version)
  end

  # Keep v1/v2 byte-for-byte stable: existing source receipts hash those bytes.
  defp encode_motion(_, false), do: []

  defp encode_motion(record, true) do
    case Map.fetch(record, :motion) do
      :error ->
        <<0>>

      {:ok, state} ->
        check(ItemMotionState.valid?(state))
        %{velocity: {x, y, z}, age: age, pickup_delay: delay} = state
        flags = 1 + if(state.on_ground, do: 2, else: 0) + if(state.no_gravity, do: 4, else: 0)
        <<flags, x::float-64, y::float-64, z::float-64, age::signed-16, delay::signed-16>>
    end
  end

  defp take_motion(body, version) when version in [1, 2], do: {nil, body}
  defp take_motion(<<0, body::binary>>, 3), do: {nil, body}

  defp take_motion(
         <<flags, x::float-64, y::float-64, z::float-64, age::signed-16, delay::signed-16,
           body::binary>>,
         3
       )
       when flags in [1, 3, 5, 7] do
    state = %ItemMotionState{
      velocity: {x, y, z},
      age: age,
      pickup_delay: delay,
      on_ground: (flags &&& 2) != 0,
      no_gravity: (flags &&& 4) != 0
    }

    check(ItemMotionState.valid?(state))
    {state, body}
  end

  defp position_valid?(key, {x, _, z} = position),
    do:
      Items.valid_position?(position) and
        Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp check(true), do: :ok
  defp check(false), do: throw({:record_error, :invalid})
end
