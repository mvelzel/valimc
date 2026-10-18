defmodule Valimc.World.ContainerTransfers do
  @moduledoc "Receipt-backed container decisions; fresh owner eligibility is supplied by the region."
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.World.{ContainerRequest, Containers, ItemReceipts}

  def reserve(%Containers{} = containers, source) do
    with {:ok, receipts, result} <- ItemReceipts.reserve(containers.receipts, source),
         do: {:ok, %{containers | receipts: receipts}, result}
  end

  def plan(%Containers{} = containers, key, request, eligible) when is_boolean(eligible) do
    with {:ok, digest} <- ContainerRequest.digest(key, request) do
      base = %{containers: containers, result: nil}

      case containers.receipts[request.source] do
        %{sequence: prior} when request.sequence < prior ->
          {:error, :stale_transfer}

        %{sequence: sequence} = receipt when sequence == request.sequence ->
          case outcome(digest, receipt.digest) do
            :applied -> {:ok, %{base | result: :already_applied}}
            :rejected -> {:ok, %{base | result: :already_rejected}}
            :conflict -> {:error, :transfer_conflict}
          end

        nil ->
          # A grant follows durable receipt-slot reservation, never speculative capacity.
          {:error, :missing_container_receipt_slot}

        _ ->
          {result, next} =
            case eligible && exchange(containers, request) do
              {:ok, next} -> {:applied, next}
              _ -> {:rejected, containers}
            end

          candidate = with_receipt(next, request, digest, result)

          case Containers.encode(key, candidate) do
            {:ok, _} ->
              {:ok, %{base | result: result, containers: candidate}}

            _ ->
              # Reserved receipts have fixed size. Rejecting retains the committed
              # contents, so a valid reserved snapshot can still record the outcome.
              rejected = with_receipt(containers, request, digest, :rejected)

              with {:ok, _} <- Containers.encode(key, rejected),
                   do: {:ok, %{base | result: :rejected, containers: rejected}}
          end
      end
    end
  end

  def receipt_result(key, request, %{sequence: sequence, digest: actual}) do
    with {:ok, digest} <- ContainerRequest.digest(key, request),
         true <- request.sequence == sequence do
      case outcome(digest, actual) do
        :conflict -> {:error, :transfer_conflict}
        result -> {:ok, result}
      end
    else
      false -> {:error, :stale_transfer}
      error -> error
    end
  end

  def receipt_result(_, _, _), do: {:error, :transfer_conflict}

  defp exchange(containers, request) do
    with {:ok, entry} <- Containers.observe(containers, request.position),
         true <- ContainerRequest.matches_entry?(request, entry),
         {:ok, next_slots, _player_result} <- ContainerRequest.plan(request) do
      if next_slots == request.slots do
        {:ok, containers}
      else
        replace(containers, request.position, entry, next_slots)
      end
    else
      _ -> {:error, :stale_container}
    end
  end

  defp replace(containers, position, %{rows: _, revision: revision}, slots) do
    with {:ok, next, _} <- Containers.replace(containers, position, revision, slots),
         do: {:ok, next}
  end

  defp replace(
         containers,
         position,
         %{kind: kind, cooking: cooking, recipes: recipes} = entry,
         slots
       ) do
    # Withdrawing earned output must include a durable XP/recipe-award decision.
    with true <- recipes == %{} or elem(slots, 2) == elem(cooking.slots, 2),
         {:ok, block} <- CookingBlocks.placement(kind, 0.0),
         {:ok, edited} <- Cooking.edit_slots(cooking, slots, block),
         {:ok, next, _} <-
           Containers.replace_cooking(containers, position, entry.revision, edited, recipes),
         do: {:ok, next}
  end

  defp outcome(digest, actual) do
    cond do
      actual == result_digest(digest, :applied) -> :applied
      actual == result_digest(digest, :rejected) -> :rejected
      true -> :conflict
    end
  end

  defp with_receipt(containers, request, digest, result) do
    receipt = %{sequence: request.sequence, digest: result_digest(digest, result)}
    %{containers | receipts: Map.put(containers.receipts, request.source, receipt)}
  end

  defp result_digest(digest, result),
    do:
      :crypto.hash(:sha256, [
        "VMCCONTAINER-RESULT",
        if(result == :applied, do: <<1>>, else: <<0>>),
        digest
      ])
end
