defmodule Valimc.PlayerPickupTransfers do
  @moduledoc "Persist the original inventory; grant only after matching terminal region proof."
  alias Valimc.{PlayerPickupIntent, PlayerSnapshot}
  alias Valimc.World.PickupTransfers
  @max_sequence 18_446_744_073_709_551_615

  def prepare(uuid, sequence, %{health: %{value: hp}} = snapshot, %{kind: :pickup} = intent)
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence and hp > 0 do
    with true <- Map.get(snapshot, :outbox) == nil,
         true <- Map.get(snapshot, :transfer_sequence, sequence) == sequence,
         {:ok, intent} <- assign_source(intent, uuid, sequence + 1),
         {:ok, bound} <- PlayerPickupIntent.bind(intent, snapshot),
         {:ok, bytes} <- PlayerPickupIntent.encode(uuid, sequence + 1, bound),
         {:ok, canonical} <- PlayerPickupIntent.decode(uuid, sequence + 1, bytes),
         true <- PlayerPickupIntent.matches_snapshot?(canonical, snapshot),
         next = Map.merge(snapshot, %{transfer_sequence: sequence + 1, outbox: canonical}),
         {:ok, _} <- PlayerSnapshot.encode(uuid, next) do
      {:ok, next}
    else
      _ -> {:error, :invalid_pickup_plan}
    end
  rescue
    _ -> {:error, :invalid_pickup_plan}
  end

  def prepare(_, _, _, _), do: {:error, :invalid_pickup_plan}

  @doc "Resolve from a matching typed receipt; a delivery acknowledgment alone never grants inventory."
  def resolve(
        uuid,
        %{transfer_sequence: sequence, outbox: %{kind: :pickup} = intent} = snapshot,
        receipt
      ) do
    with {:ok, key, request, _} <- PlayerPickupIntent.request(uuid, sequence, intent),
         {:ok, result} <- PickupTransfers.receipt_result(key, request, receipt),
         {:ok, inventory, _callback} <- PlayerPickupIntent.inventory_result(intent, snapshot) do
      inventory = if(result == :applied, do: inventory, else: snapshot.inventory)
      inventory = %{inventory | infinite_materials: snapshot.game_mode.current == :creative}

      {:ok,
       %{
         snapshot
         | inventory: inventory,
           outbox: nil
       }}
    end
  end

  def resolve(_, _, _), do: {:error, :invalid_pickup_plan}

  defp assign_source(%{request: request} = intent, uuid, sequence) do
    if Map.get(request, :source, uuid) == uuid and
         Map.get(request, :sequence, sequence) == sequence,
       do: {:ok, %{intent | request: Map.merge(request, %{source: uuid, sequence: sequence})}},
       else: {:error, :invalid_pickup_plan}
  end
end
