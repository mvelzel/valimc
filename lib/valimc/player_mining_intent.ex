defmodule Valimc.PlayerMiningIntent do
  @moduledoc "Bounded typed mining outbox; wear/loot are sampled before durable preparation."
  alias Valimc.Inventory
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.World.{ItemRecords, MiningRecord, MiningTransfers}
  @max_blocks 128
  @stack_bytes 65_536
  @max_bytes 57 + 2 * @stack_bytes + 26 + @max_blocks * 14 + ItemRecords.max_bytes() + 32
  def max_bytes, do: @max_bytes

  def encode(
        uuid,
        sequence,
        %{
          kind: :mining,
          key: {rx, rz} = key,
          permit: <<_::128>> = permit,
          target: {x, y, z} = target,
          slot: slot,
          before: before,
          after: after_tool,
          expected: expected,
          records: records
        } = intent
      )
      when is_map(expected) and map_size(expected) in 1..@max_blocks and slot in 36..44 do
    with true <- Map.has_key?(expected, target),
         {:ok, _key, _request, _digest} <- request(uuid, sequence, intent),
         {:ok, items} <- ItemRecords.encode(key, Enum.sort_by(records, & &1.uuid)),
         {:ok, blocks} <- MiningRecord.encode(key, expected, items),
         {:ok, before_bytes} <- stack_bytes(before),
         {:ok, after_bytes} <- stack_bytes(after_tool) do
      {:ok,
       <<"VMCMOUT", 1, rx::signed-32, rz::signed-32, permit::binary, x::signed-32, y::signed-32,
         z::signed-32, slot, byte_size(before_bytes)::32, byte_size(after_bytes)::32,
         byte_size(blocks)::32, before_bytes::binary, after_bytes::binary, blocks::binary>>}
    else
      _ -> {:error, :invalid_mining_intent}
    end
  rescue
    _ -> {:error, :invalid_mining_intent}
  end

  def encode(_, _, _), do: {:error, :invalid_mining_intent}

  def decode(uuid, sequence, bytes)
      when is_binary(bytes) and byte_size(bytes) in 186..@max_bytes do
    <<"VMCMOUT", 1, rx::signed-32, rz::signed-32, permit::binary-size(16), x::signed-32,
      y::signed-32, z::signed-32, slot, before_size::32, after_size::32, block_size::32,
      body::binary>> = bytes

    with true <- before_size in 1..@stack_bytes and after_size in 1..@stack_bytes,
         true <- block_size <= MiningRecord.max_bytes() and slot in 36..44,
         <<before_bytes::binary-size(^before_size), after_bytes::binary-size(^after_size),
           block_bytes::binary-size(^block_size)>> <- body,
         {:ok, before, <<>>} <- ItemStack.take(before_bytes),
         {:ok, after_tool, <<>>} <- ItemStack.take(after_bytes),
         {:ok, %{edits: expected, ledger: %{records: records, receipts: receipts}}} <-
           MiningRecord.decode(block_bytes, {rx, rz}),
         true <- receipts == %{} do
      intent = %{
        kind: :mining,
        key: {rx, rz},
        permit: permit,
        target: {x, y, z},
        slot: slot,
        before: before,
        after: after_tool,
        expected: expected,
        records: records
      }

      with {:ok, canonical} <- encode(uuid, sequence, intent),
           true <- canonical == bytes,
           do: {:ok, intent},
           else: (_ -> {:error, :invalid_mining_intent})
    else
      _ -> {:error, :invalid_mining_intent}
    end
  rescue
    _ -> {:error, :invalid_mining_intent}
  end

  def decode(_, _, _), do: {:error, :invalid_mining_intent}

  def request(uuid, sequence, %{kind: :mining, key: key} = intent) do
    request =
      Map.take(intent, [:permit, :expected, :records])
      |> Map.merge(%{source: uuid, sequence: sequence})

    with {:ok, digest} <- MiningTransfers.digest(key, request), do: {:ok, key, request, digest}
  end

  def request(_, _, _), do: {:error, :invalid_mining_intent}

  @doc "The pending source must still own exactly the prepared selected-hand stack."
  def matches_inventory?(
        %{kind: :mining, slot: slot, after: after_tool},
        %Inventory{} = inventory
      ),
      do: slot == 36 + inventory.selected and Inventory.get(inventory, slot) == after_tool

  def matches_inventory?(_, _), do: false

  defp stack_bytes(nil), do: {:ok, <<0>>}

  defp stack_bytes(%ItemStack{item_id: id} = stack) do
    if id == ItemTypes.id("air") do
      {:error, :invalid_mining_intent}
    else
      bytes = stack |> ItemStack.encode() |> IO.iodata_to_binary()

      if byte_size(bytes) <= @stack_bytes,
        do: {:ok, bytes},
        else: {:error, :invalid_mining_intent}
    end
  catch
    {:item_error, _} -> {:error, :invalid_mining_intent}
  end
end
