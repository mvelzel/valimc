defmodule Valimc.PlayerContainerTransfers do
  @moduledoc "Prepare original items, then seal only a matching durable container outcome."
  alias Valimc.{PlayerContainerIntent, PlayerSnapshot}
  alias Valimc.World.ContainerTransfers
  @max_sequence 18_446_744_073_709_551_615

  def prepare(uuid, sequence, %{health: %{value: hp}} = snapshot, %{kind: :container} = intent)
      when is_integer(sequence) and sequence >= 0 and sequence < @max_sequence and hp > 0 do
    with true <- Map.get(snapshot, :outbox) == nil,
         true <- Map.get(snapshot, :transfer_sequence, sequence) == sequence,
         {:ok, intent} <- assign_source(intent, uuid, sequence + 1),
         {:ok, bound} <- PlayerContainerIntent.bind(intent, snapshot),
         {:ok, bytes} <- PlayerContainerIntent.encode(uuid, sequence + 1, bound),
         {:ok, canonical} <- PlayerContainerIntent.decode(uuid, sequence + 1, bytes),
         next = Map.merge(snapshot, %{transfer_sequence: sequence + 1, outbox: canonical}),
         {:ok, _} <- PlayerSnapshot.encode(uuid, next) do
      {:ok, next}
    else
      _ -> {:error, :invalid_container_plan}
    end
  rescue
    _ -> {:error, :invalid_container_plan}
  end

  def prepare(_, _, _, _), do: {:error, :invalid_container_plan}

  def resolve(
        uuid,
        %{transfer_sequence: sequence, outbox: %{kind: :container} = intent} = snapshot,
        receipt
      ) do
    with {:ok, key, request, _} <- PlayerContainerIntent.request(uuid, sequence, intent),
         {:ok, result} <- ContainerTransfers.receipt_result(key, request, receipt),
         {:ok, inventory} <- PlayerContainerIntent.inventory_result(intent, snapshot) do
      inventory = if result == :applied, do: inventory, else: snapshot.inventory
      inventory = %{inventory | infinite_materials: snapshot.game_mode.current == :creative}
      next = %{snapshot | inventory: inventory, outbox: nil}

      if result == :applied do
        progress(next, request)
      else
        {:ok, next}
      end
    end
  end

  def resolve(_, _, _), do: {:error, :invalid_container_plan}

  defp progress(snapshot, %{kind: :experience, value: value}) do
    with {:ok, xp} <- Valimc.PlayerExperience.give(snapshot.progression.experience, value),
         do: {:ok, put_in(snapshot.progression.experience, xp)}
  end

  defp progress(snapshot, %{award: %{recipes: recipes}}) do
    with {:ok, progression} <-
           Valimc.PlayerProgression.learn(
             Map.get(snapshot, :progression, %Valimc.PlayerProgression{}),
             recipes
           ),
         do: {:ok, Map.put(snapshot, :progression, progression)}
  end

  defp progress(snapshot, _), do: {:ok, snapshot}

  defp assign_source(%{request: request} = intent, uuid, sequence) do
    if Map.get(request, :source, uuid) == uuid and
         Map.get(request, :sequence, sequence) == sequence,
       do: {:ok, %{intent | request: Map.merge(request, %{source: uuid, sequence: sequence})}},
       else: {:error, :invalid_container_plan}
  end
end
