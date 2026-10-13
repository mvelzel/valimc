defmodule Valimc.World.ItemRecords do
  @moduledoc "Bounded stationary preview item files; runtime handles are never persisted."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.World.Items
  @data_version 5023
  @max_count 256
  @max_bytes 524_288 + 55
  def max_bytes, do: @max_bytes

  def encode({rx, rz}, records) when is_integer(rx) and is_integer(rz) and is_list(records) do
    check(rx in -2_147_483_648..2_147_483_647 and rz in -2_147_483_648..2_147_483_647)
    records = Enum.take(records, @max_count + 1)
    check(length(records) <= @max_count)
    check(length(Enum.uniq_by(records, & &1.uuid)) == length(records))

    {parts, _} =
      Enum.map_reduce(records, 23, fn %{uuid: uuid, x: x, y: y, z: z, stack: stack}, size ->
        check(is_binary(uuid) and byte_size(uuid) == 16 and stack != nil)
        check(position_valid?({rx, rz}, {x, y, z}))
        check(stack.item_id != ItemTypes.id("air"))

        bytes = [
          <<uuid::binary-size(16), x::float-64, y::float-64, z::float-64>>,
          ItemStack.encode(stack)
        ]

        size = size + IO.iodata_length(bytes)
        check(size + 32 <= @max_bytes)
        {bytes, size}
      end)

    payload =
      IO.iodata_to_binary([
        <<"VMCITEMS", 1, @data_version::32, rx::signed-32, rz::signed-32, length(records)::16>>,
        parts
      ])

    {:ok, payload <> :crypto.hash(:sha256, payload)}
  rescue
    _ -> {:error, :invalid_item_records}
  catch
    {:record_error, _} -> {:error, :invalid_item_records}
    {:item_error, _} -> {:error, :invalid_item_records}
  end

  def encode(_, _), do: {:error, :invalid_item_records}

  def decode(bytes, {rx, rz}) when is_binary(bytes) and byte_size(bytes) in 55..@max_bytes do
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), checksum::binary-size(32)>> = bytes
    check(:crypto.hash(:sha256, payload) == checksum)

    <<"VMCITEMS", 1, @data_version::32, ^rx::signed-32, ^rz::signed-32, count::16, body::binary>> =
      payload

    check(count <= @max_count)
    {records, <<>>} = take_records(body, count, [], MapSet.new(), {rx, rz})
    {:ok, Enum.reverse(records)}
  rescue
    _ -> {:error, :invalid_item_file}
  catch
    {:record_error, _} -> {:error, :invalid_item_file}
  end

  def decode(_, _), do: {:error, :invalid_item_file}

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
