defmodule Valimc.PlayerMiningTransfers do
  @moduledoc "Trusted source mining plans and receipt-backed compensation; no RNG or destination mutation."
  alias Valimc.{GameMode, Inventory, PlayerMiningIntent, PlayerSnapshot, ToolDurability}
  alias Valimc.Physics.MiningTools
  @max_sequence 18_446_744_073_709_551_615

  @doc "The player already sampled wear/loot. Persist this result before delivering its request."
  def prepare(
        uuid,
        sequence,
        %{inventory: inventory, game_mode: %GameMode{current: :survival}, health: %{value: hp}} =
          snapshot,
        %{kind: :mining} = intent
      )
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence and hp > 0 do
    before = Inventory.held(inventory, :main)

    with true <- Map.get(snapshot, :outbox) == nil,
         false <- inventory.infinite_materials,
         true <- Map.get(snapshot, :transfer_sequence, sequence) == sequence,
         true <- intent.slot == 36 + inventory.selected and intent.before == before,
         true <- MiningTools.can_destroy?(before, false),
         true <-
           ToolDurability.valid_result?(
             before,
             Map.fetch!(intent.expected, intent.target),
             false,
             intent.after
           ),
         {:ok, bytes} <- PlayerMiningIntent.encode(uuid, sequence + 1, intent),
         {:ok, canonical} <- PlayerMiningIntent.decode(uuid, sequence + 1, bytes),
         next =
           snapshot
           |> Map.put(:inventory, replace(inventory, intent.slot, intent.after))
           |> Map.merge(%{transfer_sequence: sequence + 1, outbox: canonical}),
         {:ok, _} <- PlayerSnapshot.encode(uuid, next) do
      {:ok, next}
    else
      _ -> {:error, :invalid_mining_plan}
    end
  rescue
    _ -> {:error, :invalid_mining_plan}
  end

  def prepare(_, _, _, _), do: {:error, :invalid_mining_plan}

  @doc "Called only after the matching destination receipt proves applied or rejected."
  def resolve(%{outbox: %{kind: :mining} = intent, inventory: inventory} = snapshot, result)
      when result in [:applied, :rejected] do
    if PlayerMiningIntent.matches_inventory?(intent, inventory) do
      inventory =
        if result == :rejected,
          do: replace(inventory, intent.slot, intent.before),
          else: inventory

      {:ok, %{snapshot | inventory: inventory, outbox: nil}}
    else
      {:error, :mining_source_conflict}
    end
  end

  def resolve(_, _), do: {:error, :invalid_mining_plan}

  defp replace(inventory, slot, stack) do
    slots =
      if stack == nil,
        do: Map.delete(inventory.slots, slot),
        else: Map.put(inventory.slots, slot, stack)

    %{inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()
  end
end
