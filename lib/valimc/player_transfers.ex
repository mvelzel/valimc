defmodule Valimc.PlayerTransfers do
  @moduledoc "Conserved source plans and explicit, separately authorized creative creation."
  alias Valimc.{Inventory, PlayerDrops, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.ItemTransfers
  @max_sequence 18_446_744_073_709_551_615

  @doc "Pins a disconnected cleanup batch; callers must commit it before any delivery."
  def plan_disconnect(%{pose: pose, inventory: inventory} = snapshot) do
    with {:ok, next, stacks} <- Inventory.disconnect(inventory) do
      drop_plan(snapshot, pose, next, stacks, :directed)
    end
  end

  def plan_cleanup(%{health: %{value: health}} = snapshot) when health <= 0,
    do: plan_death(snapshot)

  def plan_cleanup(snapshot), do: plan_disconnect(snapshot)

  def plan_death(%{pose: pose, inventory: inventory, health: %{value: health}} = snapshot)
      when health <= 0 do
    with {:ok, next, stacks, _destroyed} <- Inventory.death_batch(inventory),
         do: drop_plan(snapshot, pose, next, stacks, :scattered)
  end

  def plan_death(_), do: {:error, :player_not_dead}

  defp drop_plan(snapshot, pose, next, stacks, kind) do
    with {:ok, key, records} <- PlayerDrops.records(pose, stacks, kind),
         do: {:ok, %{snapshot | inventory: next}, key, records}
  end

  def prepare(uuid, sequence, before, after_snapshot, key, records),
    do: prepare_conserved(uuid, sequence, before, after_snapshot, key, records, [])

  def prepare_death(
        uuid,
        sequence,
        %{health: %{value: health}} = before,
        after_snapshot,
        key,
        records
      )
      when health <= 0 do
    with {:ok, inventory, stacks, destroyed} <- Inventory.death_batch(before.inventory),
         true <- strip_journal(after_snapshot) == %{strip_journal(before) | inventory: inventory},
         true <- is_list(records) and Enum.map(records, & &1.stack) == stacks,
         do: prepare_conserved(uuid, sequence, before, after_snapshot, key, records, destroyed),
         else: (_ -> {:error, :invalid_death_plan})
  rescue
    _ -> {:error, :invalid_death_plan}
  end

  def prepare_death(_, _, _, _, _, _), do: {:error, :player_not_dead}

  defp prepare_conserved(uuid, sequence, before, after_snapshot, key, records, destroyed)
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
             totals(owned(after_snapshot.inventory) ++ Enum.map(records, & &1.stack) ++ destroyed) do
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

  defp prepare_conserved(_, _, _, _, _, _, _), do: {:error, :transfer_sequence_exhausted}

  @doc "Creates one new record without consuming inventory; permission comes from its trusted owner."
  def prepare_creative_drop(uuid, sequence, snapshot, key, record)
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence do
    with %{inventory: %Inventory{infinite_materials: true}} <- snapshot,
         %{stack: %ItemStack{}} <- record,
         {:ok, _} <- PlayerSnapshot.encode(uuid, strip_journal(snapshot)),
         {:ok, _, _} <-
           ItemTransfers.encode_request(key, %{
             source: uuid,
             sequence: sequence + 1,
             records: [record]
           }) do
      {:ok,
       snapshot
       |> strip_journal()
       |> Map.merge(%{
         transfer_sequence: sequence + 1,
         outbox: %{key: key, records: [record]}
       })}
    else
      %{inventory: %Inventory{}} -> {:error, :creative_drop_not_authorized}
      {:error, _} = error -> error
      _ -> {:error, :invalid_transfer_plan}
    end
  rescue
    _ -> {:error, :invalid_transfer_plan}
  end

  def prepare_creative_drop(_, _, _, _, _), do: {:error, :transfer_sequence_exhausted}

  defp strip_journal(%{pose: _, inventory: _} = snapshot),
    do:
      Map.take(snapshot, [
        :pose,
        :inventory,
        :flying,
        :game_mode,
        :fall_distance,
        :frozen_ticks,
        :air_supply,
        :fire_ticks,
        :food,
        :velocity,
        :health,
        :last_death
      ])

  defp owned(%Inventory{} = inventory), do: Inventory.contents(inventory) ++ [inventory.carried]

  defp totals(stacks) do
    Enum.reduce(stacks, %{}, fn
      nil, counts ->
        counts

      %ItemStack{} = stack, counts ->
        key = ItemStack.identity_key(stack)
        Map.update(counts, key, stack.count, &(&1 + stack.count))
    end)
  end
end
