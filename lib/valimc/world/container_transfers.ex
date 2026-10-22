defmodule Valimc.World.ContainerTransfers do
  @moduledoc """
  Receipt-backed container decisions; fresh owner eligibility is supplied by the
  region. Withdrawing a furnace's earned output decides its experience: the
  decision carries the orb records (`orbs`) the owner spawns in the same commit
  (VMC-077h).
  """
  alias Valimc.{Cooking, CookingAwards}
  alias Valimc.CookingBlocks
  alias Valimc.Txn.Receipts
  alias Valimc.World.{ContainerRequest, Containers, ExperienceOrbs}
  @scheme {:prefix, "VMCCONTAINER-RESULT"}

  def reserve(%Containers{} = containers, source) do
    with {:ok, receipts, result} <- Receipts.reserve(containers.receipts, source),
         do: {:ok, %{containers | receipts: receipts}, result}
  end

  def plan(%Containers{} = containers, key, request, eligible) when is_boolean(eligible) do
    if request[:award] do
      decide(containers, key, request, eligible, fn _digest ->
        draws =
          Map.new(request.award.recipes, fn name ->
            <<sample::24>> = :crypto.strong_rand_bytes(3)
            {name, sample}
          end)

        exchange_cooking_award(containers, request, %{
          position: request.award.position,
          draws: draws
        })
      end)
    else
      decide(containers, key, request, eligible, fn _ -> exchange(containers, request) end)
    end
  end

  defp decide(containers, key, request, eligible, exchange) do
    with {:ok, digest} <- ContainerRequest.digest(key, request) do
      base = %{containers: containers, result: nil}

      receipts = containers.receipts

      # A grant follows durable receipt-slot reservation, never speculative capacity.
      case receipts[request.source] &&
             Receipts.classify(receipts, request.source, request.sequence, digest, @scheme) do
        nil ->
          {:error, :missing_container_receipt_slot}

        {:duplicate, result} ->
          {:ok, %{base | result: result}}

        {:error, _} = error ->
          error

        :new ->
          {result, next, orbs} =
            case eligible && exchange.(digest) do
              {:ok, next, orbs} -> {:applied, next, orbs}
              {:ok, next} -> {:applied, next, []}
              _ -> {:rejected, containers, []}
            end

          candidate = with_receipt(next, request, digest, result)

          case Containers.encode(key, candidate) do
            {:ok, _} ->
              {:ok, Map.merge(base, %{result: result, containers: candidate, orbs: orbs})}

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

  def receipt_result(key, request, receipt) do
    with {:ok, digest} <- ContainerRequest.digest(key, request),
         do: Receipts.outcome(receipt, request.sequence, digest, @scheme)
  end

  defp exchange_cooking_award(containers, request, %{position: position, draws: draws} = context)
       when map_size(context) == 2 do
    with {:ok, %{kind: kind, cooking: cooking, recipes: uses} = entry} <-
           Containers.observe(containers, request.position),
         true <- uses != %{} and ContainerRequest.matches_entry?(request, entry),
         true <- request[:award] == nil or request.award.recipes == Enum.sort(Map.keys(uses)),
         {:ok, slots, _inventory} <- ContainerRequest.plan(request),
         true <- withdrawal?(elem(cooking.slots, 2), elem(slots, 2)),
         {:ok, award} <- CookingAwards.plan(uses, draws),
         {:ok, block} <- CookingBlocks.placement(kind, 0.0),
         {:ok, edited} <- Cooking.edit_slots(cooking, slots, block),
         {:ok, next, _} <-
           Containers.replace_cooking(containers, request.position, entry.revision, edited, %{}) do
      {:ok, next, ExperienceOrbs.award(position, award)}
    else
      _ -> {:error, :invalid_cooking_award_transfer}
    end
  end

  defp exchange_cooking_award(_, _, _), do: {:error, :invalid_cooking_award_transfer}
  defp withdrawal?(nil, _), do: false
  defp withdrawal?(_, nil), do: true

  defp withdrawal?(before, after_stack),
    do:
      Valimc.Protocol.ItemStack.same_item?(before, after_stack) and
        after_stack.count < before.count

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

  defp with_receipt(containers, request, digest, result) do
    receipts =
      Receipts.record(
        containers.receipts,
        request.source,
        request.sequence,
        digest,
        @scheme,
        result
      )

    %{containers | receipts: receipts}
  end

  @doc false
  def result_digest(<<_::256>> = digest, result) when result in [:applied, :rejected],
    do: Receipts.stored(@scheme, digest, result)
end
