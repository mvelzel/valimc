defmodule Valimc.World.ItemLedger do
  @moduledoc "Bounded regional handoff metadata around unchanged legacy player-item records."
  alias Valimc.World.{ItemRecords, ItemMergeTransfer, OwnerItemReceipts}
  defstruct sequence: 0, outgoing: nil, incoming: %{}, generations: %{}
  @max_sequence 18_446_744_073_709_551_615
  @max_receipts 4096
  @outgoing_bytes 524_345
  @max_bytes ItemRecords.max_bytes() + @outgoing_bytes + @max_receipts * 48 + 288 * 24 + 96
  def max_bytes, do: @max_bytes

  @doc "Empty ledger state keeps the exact v1/v2/v3 ItemRecords representation."
  def encode(key, records, receipts, ledger \\ %__MODULE__{}) do
    with true <- valid?(key, records, ledger),
         {:ok, owned} <- ItemRecords.encode(key, records, receipts) do
      if ledger == %__MODULE__{} do
        {:ok, owned}
      else
        {rx, rz} = key

        payload =
          IO.iodata_to_binary([
            <<"VMCLEDGR", 1, 5023::32, rx::signed-32, rz::signed-32, ledger.sequence::64,
              map_size(ledger.incoming)::16, map_size(ledger.generations)::16,
              byte_size(owned)::32>>,
            owned,
            ledger.incoming
            |> Enum.sort()
            |> Enum.map(fn {{sx, sz}, r} ->
              <<sx::signed-32, sz::signed-32, r.sequence::64, r.digest::binary-size(32)>>
            end),
            generations(ledger.generations),
            outgoing(ledger.outgoing)
          ])

        bytes = payload <> :crypto.hash(:sha256, payload)
        if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
      end
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  def decode(bytes, key) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    case bytes do
      <<"VMCITEMS", _::binary>> ->
        case ItemRecords.decode(bytes, key) do
          {:ok, data} -> {:ok, Map.put(data, :ledger, %__MODULE__{})}
          _ -> invalid()
        end

      <<"VMCLEDGR", _::binary>> ->
        decode_ledger(bytes, key)

      _ ->
        invalid()
    end
  rescue
    _ -> invalid()
  end

  def decode(_, _), do: invalid()

  defp decode_ledger(bytes, {rx, rz} = key) do
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), checksum::binary-size(32)>> = bytes
    true = :crypto.hash(:sha256, payload) == checksum

    <<"VMCLEDGR", 1, 5023::32, ^rx::signed-32, ^rz::signed-32, sequence::64, count::16,
      owners::16, length::32, rest::binary>> = payload

    true = count <= @max_receipts and owners <= 256 and length <= ItemRecords.max_bytes()
    <<owned::binary-size(^length), rest::binary>> = rest
    {:ok, %{records: records, receipts: receipts}} = ItemRecords.decode(owned, key)
    {incoming, rest} = take_receipts(rest, count, %{})
    {generations, rest} = take_generations(rest, owners, %{})
    outgoing = take_outgoing(rest)

    ledger = %__MODULE__{
      sequence: sequence,
      outgoing: outgoing,
      incoming: incoming,
      generations: generations
    }

    # Reject duplicate/unsorted metadata and wrappers that should have stayed legacy.
    {:ok, ^bytes} = encode(key, records, receipts, ledger)
    {:ok, %{records: records, receipts: receipts, ledger: ledger}}
  end

  defp take_receipts(rest, 0, acc), do: {acc, rest}

  defp take_receipts(
         <<x::signed-32, z::signed-32, sequence::64, digest::binary-size(32), rest::binary>>,
         n,
         acc
       ) do
    false = Map.has_key?(acc, {x, z})
    take_receipts(rest, n - 1, Map.put(acc, {x, z}, %{sequence: sequence, digest: digest}))
  end

  defp take_generations(rest, 0, acc), do: {acc, rest}

  defp take_generations(<<uuid::binary-size(16), generation::64, rest::binary>>, n, acc) do
    false = Map.has_key?(acc, uuid)
    take_generations(rest, n - 1, Map.put(acc, uuid, generation))
  end

  defp outgoing(nil), do: <<0>>

  defp outgoing(%{kind: :merge, request: request}) do
    {:ok, bytes} = ItemMergeTransfer.encode(request)
    <<2, byte_size(bytes)::32, bytes::binary>>
  end

  defp outgoing(%{destination: {x, z}, records: records, generations: hops}) do
    records = Enum.sort_by(records, & &1.uuid)
    {:ok, bytes} = ItemRecords.encode({x, z}, records)

    [
      <<1, x::signed-32, z::signed-32, byte_size(bytes)::32>>,
      bytes,
      <<map_size(hops)>>,
      generations(hops)
    ]
  end

  defp take_outgoing(<<0>>), do: nil

  defp take_outgoing(<<2, length::32, rest::binary>>) do
    true = length <= ItemMergeTransfer.max_bytes()
    <<bytes::binary-size(^length)>> = rest
    {:ok, request} = ItemMergeTransfer.decode(bytes)
    {:ok, escrow} = ItemMergeTransfer.escrow(request)
    escrow
  end

  defp take_outgoing(<<1, x::signed-32, z::signed-32, length::32, rest::binary>>) do
    true = length <= @outgoing_bytes
    <<bytes::binary-size(^length), count, rest::binary>> = rest
    true = count in 1..32
    {:ok, %{records: records, receipts: receipts}} = ItemRecords.decode(bytes, {x, z})
    true = receipts == %{}
    {generations, <<>>} = take_generations(rest, count, %{})
    %{destination: {x, z}, records: records, generations: generations}
  end

  defp generations(map),
    do: map |> Enum.sort() |> Enum.map(fn {uuid, hop} -> <<uuid::binary-size(16), hop::64>> end)

  defp valid?(key, records, %__MODULE__{} = ledger) do
    map_size(ledger) == 5 and region?(key) and sequence?(ledger.sequence, true) and
      is_list(records) and length(Enum.take(records, 257)) + return_slots(ledger.outgoing) <= 256 and
      is_map(ledger.incoming) and map_size(ledger.incoming) <= @max_receipts and
      Enum.all?(ledger.incoming, fn {source, r} ->
        region?(source) and source != key and OwnerItemReceipts.valid?(r)
      end) and valid_generations?(ledger.generations, records, false) and
      valid_outgoing?(ledger.outgoing, key, ledger.sequence) and
      disjoint?(records, ledger.outgoing)
  end

  defp valid?(_, _, _), do: false

  defp valid_outgoing?(nil, _, _), do: true

  defp valid_outgoing?(%{kind: :merge, request: request} = outgoing, key, sequence) do
    request.source == key and request.sequence == sequence and
      case ItemMergeTransfer.escrow(request) do
        {:ok, ^outgoing} -> true
        _ -> false
      end
  end

  defp valid_outgoing?(
         %{destination: destination, records: records, generations: hops} = outgoing,
         key,
         sequence
       ) do
    map_size(outgoing) == 3 and sequence > 0 and region?(destination) and destination != key and
      is_list(records) and length(Enum.take(records, 33)) in 1..32 and
      valid_generations?(hops, records, true) and
      case ItemRecords.encode(destination, records) do
        {:ok, bytes} -> byte_size(bytes) <= @outgoing_bytes
        _ -> false
      end
  end

  defp valid_outgoing?(_, _, _), do: false

  defp valid_generations?(map, records, exact) when is_map(map) do
    uuids = MapSet.new(records, & &1.uuid)

    map_size(map) <= 256 and (not exact or map_size(map) == MapSet.size(uuids)) and
      Enum.all?(map, fn {uuid, hop} ->
        is_binary(uuid) and byte_size(uuid) == 16 and MapSet.member?(uuids, uuid) and
          sequence?(hop, false)
      end)
  end

  defp valid_generations?(_, _, _), do: false

  defp disjoint?(_, nil), do: true

  defp disjoint?(owned, %{kind: :merge, request: request}),
    do: not Enum.any?(owned, &(&1.uuid == request.donor.uuid))

  defp disjoint?(owned, %{records: outgoing}) do
    MapSet.disjoint?(MapSet.new(owned, & &1.uuid), MapSet.new(outgoing, & &1.uuid))
  end

  defp return_slots(%{kind: :merge}), do: 1
  defp return_slots(_), do: 0

  defp region?({x, z}),
    do:
      is_integer(x) and is_integer(z) and x in -2_147_483_648..2_147_483_647 and
        z in -2_147_483_648..2_147_483_647

  defp region?(_), do: false

  defp sequence?(n, zero),
    do: is_integer(n) and n >= if(zero, do: 0, else: 1) and n <= @max_sequence

  defp invalid, do: {:error, :invalid_item_ledger}
end
