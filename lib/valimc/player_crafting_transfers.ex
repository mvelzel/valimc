defmodule Valimc.PlayerCraftingTransfers do
  @moduledoc "Exact recipe-conversion authorization before durable output delivery."
  alias Valimc.{Inventory, World}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.World.ItemTransfers
  @max_sequence 18_446_744_073_709_551_615

  def prepare(uuid, sequence, before, after_snapshot, key, records, {action, button})
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence and
             ((action == :quick_move and button in [0, 1]) or
                (action == :pickup and button in [0, 1]) or
                (action == :swap and (button in 0..8 or button == 40)) or
                (action == :throw and button in -128..127)) do
    with {:ok, inventory, [_ | _] = stacks} when length(stacks) <= 5 <-
           Inventory.plan_click(before.inventory, action, 0, button),
         true <- strip_journal(after_snapshot) == %{strip_journal(before) | inventory: inventory},
         true <- is_list(records) and Enum.map(records, & &1.stack) == stacks,
         true <- key == World.region_key(World.chunk_key(before.pose.x, before.pose.z)),
         true <- Enum.all?(records, &at_source?(&1, before.pose)),
         {:ok, _} <- PlayerState.encode(uuid, strip_journal(before)),
         {:ok, _} <- PlayerState.encode(uuid, strip_journal(after_snapshot)),
         {:ok, _, _} <-
           ItemTransfers.encode_request(key, %{
             source: uuid,
             sequence: sequence + 1,
             records: records
           }) do
      {:ok,
       after_snapshot
       |> strip_journal()
       |> Map.merge(%{transfer_sequence: sequence + 1, outbox: %{key: key, records: records}})}
    else
      _ -> {:error, :invalid_crafting_transfer}
    end
  rescue
    _ -> {:error, :invalid_crafting_transfer}
  catch
    _, _ -> {:error, :invalid_crafting_transfer}
  end

  def prepare(_, sequence, _, _, _, _, _)
      when not is_integer(sequence) or sequence < 0 or sequence >= @max_sequence,
      do: {:error, :transfer_sequence_exhausted}

  def prepare(_, _, _, _, _, _, _), do: {:error, :invalid_crafting_transfer}

  defp at_source?(record, pose),
    do: Valimc.PlayerDrops.at_source?(record, pose)

  defp strip_journal(snapshot), do: PlayerState.strip(snapshot)
end
