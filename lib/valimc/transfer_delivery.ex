defmodule Valimc.TransferDelivery do
  @moduledoc "Bounded destination I/O jobs; source inventory/leases remain with their owners."
  alias Valimc.World
  alias Valimc.World.Region

  def start(owner, token, uuid, intent) do
    case Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
           result = deliver(uuid, intent)
           send(owner, {:transfer_delivered, self(), token, result})
         end) do
      {:ok, worker} -> {:ok, %{pid: worker, monitor: Process.monitor(worker), token: token}}
      {:error, :max_children} -> {:error, :transfer_workers_busy}
      {:error, _} -> {:error, :region_restarting}
    end
  catch
    :exit, _ -> {:error, :region_restarting}
  end

  def retryable?({:error, reason}),
    do:
      reason in [
        :transfer_workers_busy,
        :item_workers_busy,
        :item_storage_busy,
        :mining_storage_busy,
        :region_restarting,
        :stale_region,
        :item_commit_uncertain,
        :container_commit_uncertain,
        :max_children,
        :item_count_limit,
        :item_byte_limit,
        :transfer_source_limit,
        :transfer_destination_unavailable,
        :transfer_not_applied
      ]

  def retryable?(_), do: false

  def completed?(%{outbox: %{kind: kind}}, result)
      when kind in [:mining, :placement, :pickup, :container],
      do:
        result in [
          {:ok, :applied},
          {:ok, :already_applied},
          {:ok, :rejected},
          {:ok, :already_rejected}
        ]

  def completed?(_intent, result), do: result in [{:ok, :applied}, {:ok, :already_applied}]

  defp deliver(uuid, %{transfer_sequence: sequence, outbox: %{kind: :mining} = intent}) do
    with {:ok, key, request, _digest} <- Valimc.PlayerMiningIntent.request(uuid, sequence, intent),
         {:ok, owner} <- World.item_owner(key),
         :ok <- persistent_destination(owner, uuid) do
      Region.apply_mining_transfer(owner, request)
    end
  rescue
    _ -> {:error, :invalid_mining_transfer}
  catch
    :exit, _ -> {:error, :region_restarting}
  end

  defp deliver(uuid, %{transfer_sequence: sequence, outbox: %{kind: :placement} = intent}) do
    with {:ok, key, request, _digest} <-
           Valimc.PlayerPlacementIntent.request(uuid, sequence, intent),
         {:ok, owner} <- World.item_owner(key),
         :ok <- persistent_destination(owner, uuid) do
      Region.apply_placement_transfer(owner, request)
    end
  rescue
    _ -> {:error, :invalid_placement_transfer}
  catch
    :exit, _ -> {:error, :region_restarting}
  end

  defp deliver(uuid, %{transfer_sequence: sequence, outbox: %{kind: :pickup} = intent}) do
    with {:ok, key, request, _digest} <- Valimc.PlayerPickupIntent.request(uuid, sequence, intent),
         {:ok, owner} <- World.item_owner(key),
         :ok <- persistent_destination(owner, uuid) do
      Region.apply_pickup_transfer(owner, request)
    end
  rescue
    _ -> {:error, :invalid_pickup_request}
  catch
    :exit, _ -> {:error, :region_restarting}
  end

  defp deliver(uuid, %{transfer_sequence: sequence, outbox: %{kind: :container} = intent}) do
    with {:ok, key, request, _} <- Valimc.PlayerContainerIntent.request(uuid, sequence, intent),
         {:ok, owner} <- World.item_owner(key) do
      Region.container_transfer(owner, request)
    end
  rescue
    _ -> {:error, :invalid_container_request}
  catch
    :exit, _ -> {:error, :region_restarting}
  end

  defp deliver(uuid, intent) do
    with {:ok, key, request, _digest} <- Valimc.PlayerSnapshot.transfer_request(uuid, intent),
         {:ok, owner} <- World.item_owner(key),
         :ok <- persistent_destination(owner, uuid) do
      Region.apply_item_transfer(owner, request)
    end
  rescue
    _ -> {:error, :invalid_transfer}
  catch
    # The region may commit before the job sees its reply. Retry only the pinned intent.
    :exit, _ -> {:error, :region_restarting}
  end

  defp persistent_destination(owner, uuid) do
    case Region.item_transfer_receipt(owner, uuid) do
      {:ok, _} -> :ok
      {:error, :missing_transfer_receipt} -> :ok
      error -> error
    end
  end
end
