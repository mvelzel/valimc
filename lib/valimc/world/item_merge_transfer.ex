defmodule Valimc.World.ItemMergeTransfer do
  @moduledoc "Bounded cross-owner merge proposal and typed proof; no mutation or ownership is conferred."
  alias Valimc.Physics.ItemMerge
  alias Valimc.World.ItemRecords
  @maximum 18_446_744_073_709_551_615
  @record_bytes 65_664
  @header_bytes 76
  @max_bytes @header_bytes + 2 * @record_bytes
  def max_bytes, do: @max_bytes

  def encode(
        %{
          source: {sx, sz} = source,
          destination: {dx, dz} = destination,
          sequence: sequence,
          permit: <<_::128>> = permit,
          donor: donor,
          donor_generation: dg,
          recipient: recipient,
          recipient_generation: rg
        } = request
      )
      when map_size(request) == 8 and is_integer(sequence) and sequence in 1..@maximum and
             is_integer(dg) and dg >= 0 and dg < @maximum and is_integer(rg) and rg in 0..@maximum do
    with true <- source != destination and region?(source) and region?(destination),
         true <- record?(donor) and record?(recipient) and donor.uuid != recipient.uuid,
         {:ok, db} <- ItemRecords.encode(source, [donor]),
         {:ok, rb} <- ItemRecords.encode(destination, [recipient]),
         true <- byte_size(db) <= @record_bytes and byte_size(rb) <= @record_bytes do
      {:ok,
       <<"VMCXMRG", 1, 5023::32, sx::signed-32, sz::signed-32, dx::signed-32, dz::signed-32,
         sequence::64, permit::binary-size(16), dg::64, rg::64, byte_size(db)::32,
         byte_size(rb)::32, db::binary, rb::binary>>}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  def encode(_), do: invalid()

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in @header_bytes..@max_bytes do
    with <<"VMCXMRG", 1, 5023::32, sx::signed-32, sz::signed-32, dx::signed-32, dz::signed-32,
           sequence::64, permit::binary-size(16), dg::64, rg::64, ds::32, rs::32, body::binary>> <-
           bytes,
         true <- ds in 1..@record_bytes and rs in 1..@record_bytes,
         <<db::binary-size(^ds), rb::binary-size(^rs)>> <- body,
         {:ok, %{records: [donor], receipts: receipts}} <- ItemRecords.decode(db, {sx, sz}),
         true <- receipts == %{},
         {:ok, %{records: [recipient], receipts: receipts}} <- ItemRecords.decode(rb, {dx, dz}),
         true <- receipts == %{},
         request = %{
           source: {sx, sz},
           destination: {dx, dz},
           sequence: sequence,
           permit: permit,
           donor: donor,
           donor_generation: dg,
           recipient: recipient,
           recipient_generation: rg
         },
         {:ok, ^bytes} <- encode(request) do
      {:ok, request}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  def decode(_), do: invalid()

  def digest(request) do
    with {:ok, bytes} <- encode(request), do: {:ok, :crypto.hash(:sha256, bytes)}
  end

  @doc "Reserve one return slot and its worst-case packet bytes while the donor is escrowed."
  def escrow(request) do
    with {:ok, _} <- decision(request) do
      # Counts1..99 occupy one VarInt byte, including native reverse-flow returns.
      # 256 covers all four packets' scalar/identity fields at the largest runtime ID.
      bytes = IO.iodata_length(Valimc.Protocol.ItemStack.encode(request.donor.stack)) + 256
      {:ok, %{kind: :merge, request: request, return_bytes: bytes}}
    end
  end

  @doc "The request always withdraws from the donor owner; native equal-count ties choose the supplied recipient."
  def decision(request) do
    with {:ok, _} <- encode(request),
         true <- ItemMerge.near?(point(request.donor), point(request.recipient)),
         {:ok, %{recipient: :b} = result} <-
           ItemMerge.pair(input(request.donor), input(request.recipient)) do
      {:ok, result}
    else
      _ -> {:error, :not_mergeable}
    end
  end

  def receipt(request, result) when result in [:applied, :rejected] do
    with {:ok, digest} <- digest(request) do
      {:ok,
       %{
         sequence: request.sequence,
         digest:
           :crypto.hash(:sha256, [
             "VMCXMRG-RESULT",
             digest,
             <<if(result == :applied, do: 1, else: 0)>>
           ])
       }}
    end
  end

  def receipt(_, _), do: invalid()

  def receipt_result(request, receipt) do
    with {:ok, applied} <- receipt(request, :applied),
         {:ok, rejected} <- receipt(request, :rejected) do
      cond do
        receipt == applied ->
          {:ok, :applied}

        receipt == rejected ->
          {:ok, :rejected}

        is_map(receipt) and is_integer(receipt[:sequence]) and receipt.sequence > request.sequence ->
          {:error, :stale_item_merge}

        true ->
          {:error, :item_merge_receipt_conflict}
      end
    end
  end

  defp point(record), do: {record.x, record.y, record.z}
  defp input(record), do: %{stack: record.stack, motion: record.motion, target: nil, alive: true}

  defp record?(
         %{uuid: <<_::128>>, x: _, y: _, z: _, stack: _, motion: %Valimc.ItemMotionState{}} =
           record
       ),
       do: map_size(record) == 6

  defp record?(_), do: false

  defp region?({x, z}),
    do:
      is_integer(x) and is_integer(z) and
        x in -2_147_483_648..2_147_483_647 and z in -2_147_483_648..2_147_483_647

  defp invalid, do: {:error, :invalid_item_merge_transfer}
end
