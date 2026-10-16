defmodule Valimc.World.ItemCrossMergeQuery do
  @moduledoc "Bounded cross-owner discovery and I/O; only owners authorize and commit effects."
  alias Valimc.{Metrics, Physics.ItemMerge, World}
  alias Valimc.World.{ItemMergeTransfer, Region}

  @fields [
    :entity_id,
    :uuid,
    :epoch,
    :at,
    :merge_key,
    :count,
    :merge_max,
    :physical_revision
  ]
  @attempts 8

  # Called at most every200ms. Fingerprints are computed on stack changes, never
  # while ticking counters; immutable observations carry no gameplay authority.
  def scene({rx, rz} = key, views) do
    width = Valimc.config(:region_size) * 16

    donors =
      views |> Map.values() |> Enum.filter(&(&1.merge_open and border?(&1.at, rx, rz, width)))

    if donors == [] do
      nil
    else
      targets =
        for x <- (rx - 1)..(rx + 1),
            z <- (rz - 1)..(rz + 1),
            {x, z} != key,
            view <- Map.values(World.item_snapshot({x, z})),
            view.merge_open and adjacent?(view.at, rx, rz, width),
            do: Map.put(Map.take(view, @fields), :key, {x, z})

      donors = donors |> Enum.map(&Map.take(&1, @fields)) |> Enum.sort_by(& &1.entity_id)
      targets = Enum.sort_by(targets, & &1.entity_id)
      %{donors: donors, targets: targets, stamp: {stamp(donors), stamp(targets)}}
    end
  end

  def start(owner, epoch, token, key, scene, cursor) do
    case Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
           Process.link(owner)
           result = run({owner, epoch}, key, scene, cursor)
           send(owner, {:resource, epoch, {:item_cross_query, self(), token, result}})
         end) do
      {:ok, worker} -> {:ok, worker, Process.monitor(worker)}
      {:error, _} -> {:error, :item_cross_workers_busy}
    end
  catch
    :exit, _ -> {:error, :item_cross_workers_busy}
  end

  defp run(owner, key, scene, cursor) do
    targets = Enum.group_by(scene.targets, & &1.merge_key)
    # Lazy traversal bounds retained pairs even for a crowded eight-neighbor scene.
    pairs =
      scene.donors
      |> Stream.flat_map(fn donor ->
        Stream.map(Map.get(targets, donor.merge_key, []), &{donor, &1})
      end)
      |> Stream.filter(fn {a, b} ->
        (cursor == nil or {a.entity_id, b.entity_id} > cursor) and
          a.count <= b.count and
          (a.count != b.count or key < b.key) and a.count + b.count <= b.merge_max and
          ItemMerge.near?(a.at, b.at)
      end)
      |> Enum.take(@attempts + 1)

    loop(Enum.take(pairs, @attempts), owner, key, length(pairs) > @attempts, false, nil)
  end

  defp loop([], _, _, more, retry, cursor),
    do: %{cursor: if(more, do: cursor), retry: retry, progress: false}

  defp loop([{donor, target} | rest], owner, key, more, retry, _) do
    Metrics.add(:item_cross_attempts)

    case attempt(owner, donor, target) do
      :prepared ->
        Metrics.add(:item_cross_prepared)
        %{cursor: nil, retry: true, progress: true}

      result ->
        if result == :retry, do: Metrics.add(:item_cross_retries)

        loop(
          rest,
          owner,
          key,
          more,
          retry or result == :retry,
          {donor.entity_id, target.entity_id}
        )
    end
  end

  defp attempt(source, donor, target) do
    with {:ok, proposal, fence} <- Region.item_merge_donor(source, donor.uuid, target.uuid),
         {:ok, {_, epoch} = recipient} when epoch == target.epoch <-
           World.existing_owner(target.key),
         {:ok, request} <- Region.reserve_item_merge(recipient, proposal) do
      result =
        with {:ok, decision} <- ItemMergeTransfer.decision(request) do
          if decision.stack == request.recipient.stack and
               decision.donor_stack == request.donor.stack do
            case Region.apply_item_merge_counters(recipient, request, fence) do
              {:ok, status} when status in [:applied, :unchanged] -> :counters
              _ -> :retry
            end
          else
            case Region.prepare_item_merge(source, request) do
              {:ok, :prepared} -> :prepared
              _ -> :retry
            end
          end
        else
          _ -> :retry
        end

      # A prepared durable journal owns the grant until delivery; all other paths
      # release unused admission. Aborted jobs leave only a bounded expiring grant.
      if result != :prepared,
        do: Region.release_item_merge(recipient, request.permit, request.source)

      result
    else
      _ -> :retry
    end
  catch
    :exit, _ -> :retry
  end

  defp stamp(views),
    do: Enum.map(views, &{&1.entity_id, &1.epoch, &1.physical_revision})

  defp border?({x, _, z}, rx, rz, width),
    do:
      x < rx * width + 0.75 or x > (rx + 1) * width - 0.75 or
        z < rz * width + 0.75 or z > (rz + 1) * width - 0.75

  defp adjacent?({x, _, z}, rx, rz, width),
    do:
      x > rx * width - 0.75 and x < (rx + 1) * width + 0.75 and
        z > rz * width - 0.75 and z < (rz + 1) * width + 0.75
end
