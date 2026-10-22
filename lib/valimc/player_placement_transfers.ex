defmodule Valimc.PlayerPlacementTransfers do
  @moduledoc "Leased source placement plans and receipt-backed exact-stack refunds."
  alias Valimc.{GameMode, Inventory, PlayerPlacementIntent}
  alias Valimc.Player.State, as: PlayerState
  @max_sequence 18_446_744_073_709_551_615

  def prepare(
        uuid,
        sequence,
        %{
          inventory: %Inventory{} = inventory,
          game_mode: %GameMode{current: :survival},
          health: %{value: hp}
        } = snapshot,
        %{kind: :placement} = intent
      )
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence and hp > 0 do
    with true <- Map.get(snapshot, :outbox) == nil,
         false <- inventory.infinite_materials,
         true <- Map.get(snapshot, :transfer_sequence, sequence) == sequence,
         true <-
           intent.slot == if(intent.request.hand == :off, do: 45, else: 36 + inventory.selected),
         true <- Inventory.get(inventory, intent.slot) == intent.before,
         {:ok, bytes} <- PlayerPlacementIntent.encode(uuid, sequence + 1, intent),
         {:ok, canonical} <- PlayerPlacementIntent.decode(uuid, sequence + 1, bytes),
         next =
           snapshot
           |> Map.put(:inventory, replace(inventory, intent.slot, intent.after))
           |> Map.merge(%{transfer_sequence: sequence + 1, outbox: canonical}),
         {:ok, _} <- PlayerState.encode(uuid, next) do
      {:ok, next}
    else
      _ -> {:error, :invalid_placement_plan}
    end
  rescue
    _ -> {:error, :invalid_placement_plan}
  end

  def prepare(_, _, _, _), do: {:error, :invalid_placement_plan}

  @doc "The source writer calls this only after matching terminal destination proof."
  def resolve(%{outbox: %{kind: :placement} = intent, inventory: inventory} = snapshot, result)
      when result in [:applied, :rejected] do
    if PlayerPlacementIntent.matches_inventory?(intent, inventory) do
      inventory =
        if result == :rejected,
          do: replace(inventory, intent.slot, intent.before),
          else: inventory

      {:ok, %{snapshot | inventory: inventory, outbox: nil}}
    else
      {:error, :placement_source_conflict}
    end
  end

  def resolve(_, _), do: {:error, :invalid_placement_plan}

  defp replace(inventory, slot, stack) do
    slots =
      if stack == nil,
        do: Map.delete(inventory.slots, slot),
        else: Map.put(inventory.slots, slot, stack)

    %{inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()
  end
end
