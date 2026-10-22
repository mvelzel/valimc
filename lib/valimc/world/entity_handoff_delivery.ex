defmodule Valimc.World.EntityHandoffDelivery do
  @moduledoc "One bounded destination I/O attempt; the source retains its durable intent until receipt."
  alias Valimc.World
  alias Valimc.World.{EntityHandoffs, Region}

  @doc "The owner job delivering region `key`'s outgoing intent once: `{:ok, sequence, digest, result}`."
  def work(key, ledger), do: fn -> deliver(key, ledger) end

  defp deliver(key, ledger) do
    with {:ok, request} <- EntityHandoffs.request(%{ledger: ledger}, key),
         {:ok, digest} <- EntityHandoffs.digest(request),
         {:ok, owner} <- owner(request.destination),
         {:ok, result} <- Region.apply_entity_handoff(owner, request),
         {:ok, result} <- outcome(result),
         do: {:ok, request.sequence, digest, result}
  catch
    :exit, _ -> {:error, :item_handoff_uncertain}
  end

  defp outcome(result) when result in [:applied, :already_applied], do: {:ok, :applied}
  defp outcome(result) when result in [:rejected, :already_rejected], do: {:ok, :rejected}
  defp outcome(_), do: {:error, :item_handoff_uncertain}

  # Another dimension's section (VMC-026c) is found, and loaded, the same way.
  defp owner(section), do: World.item_owner(section)
end
