defmodule Valimc.World.ItemHandoffDelivery do
  @moduledoc "One bounded destination I/O attempt; the source retains its durable intent until receipt."
  alias Valimc.World
  alias Valimc.World.{ItemHandoffs, Region}

  def start(owner, epoch, token, key, ledger) do
    case Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
           Process.link(owner)
           result = deliver(key, ledger)
           send(owner, {:resource, epoch, {:item_handoff_delivered, self(), token, result}})
         end) do
      {:ok, worker} -> {:ok, worker, Process.monitor(worker)}
      {:error, _} -> {:error, :item_handoff_workers_busy}
    end
  catch
    :exit, _ -> {:error, :item_handoff_workers_busy}
  end

  defp deliver(key, ledger) do
    with {:ok, request} <- ItemHandoffs.request(%{ledger: ledger}, key),
         {:ok, digest} <- ItemHandoffs.digest(request.destination, request),
         {:ok, owner} <- World.item_owner(request.destination),
         {:ok, result} when result in [:applied, :already_applied] <-
           Region.apply_item_handoff(owner, request),
         do: {:ok, request.sequence, digest}
  catch
    :exit, _ -> {:error, :item_handoff_uncertain}
  end
end
