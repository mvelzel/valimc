defmodule Valimc.PlayerTransfers do
  @moduledoc "Pure source plans: supported inventory ownership must equal retained plus transferred stacks."
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.ItemTransfers
  @max_sequence 18_446_744_073_709_551_615

  def prepare(uuid, sequence, before, after_snapshot, key, records)
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence do
    with {:ok, _} <- PlayerSnapshot.encode(uuid, strip_journal(before)),
         {:ok, _} <- PlayerSnapshot.encode(uuid, strip_journal(after_snapshot)),
         {:ok, _, _} <-
           ItemTransfers.encode_request(key, %{
             source: uuid,
             sequence: sequence + 1,
             records: records
           }),
         true <-
           totals(owned(before.inventory)) ==
             totals(owned(after_snapshot.inventory) ++ Enum.map(records, & &1.stack)) do
      {:ok,
       after_snapshot
       |> strip_journal()
       |> Map.merge(%{
         transfer_sequence: sequence + 1,
         outbox: %{key: key, records: records}
       })}
    else
      false -> {:error, :item_conservation_failed}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_transfer_plan}
  end

  def prepare(_, _, _, _, _, _), do: {:error, :transfer_sequence_exhausted}

  defp strip_journal(%{pose: _, inventory: _} = snapshot),
    do: Map.take(snapshot, [:pose, :inventory])

  defp owned(%Inventory{} = inventory), do: Inventory.contents(inventory) ++ [inventory.carried]

  defp totals(stacks) do
    Enum.reduce(stacks, %{}, fn
      nil, counts ->
        counts

      %ItemStack{} = stack, counts ->
        key = IO.iodata_to_binary(ItemStack.encode(%{stack | count: 1}))
        Map.update(counts, key, stack.count, &(&1 + stack.count))
    end)
  end
end
