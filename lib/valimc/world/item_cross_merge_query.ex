defmodule Valimc.World.ItemCrossMergeQuery do
  @moduledoc """
  Cross-owner merge discovery over published snapshots (observations, no
  authority): this owner's border items that could merge into a neighbour's.
  The owner then hands the donor over to merge on arrival
  (`Valimc.World.EntityHandoffs`), and the neighbour decides.
  """
  alias Valimc.{Physics.ItemMerge, World}

  @fields [:entity_id, :uuid, :at, :merge_key, :count, :merge_max, :physical_revision]

  # Called at most every 200 ms. Fingerprints are computed on stack changes,
  # never while ticking counters.
  def scene({rx, rz} = key, views) do
    width = Valimc.config(:region_size) * 16

    donors =
      views
      |> Map.values()
      |> Enum.filter(&(&1.kind == :item and &1.merge_open and border?(&1.at, rx, rz, width)))

    if donors == [] do
      nil
    else
      targets =
        for x <- (rx - 1)..(rx + 1),
            z <- (rz - 1)..(rz + 1),
            {x, z} != key,
            view <- Map.values(World.item_snapshot({x, z})),
            view.kind == :item and view.merge_open and adjacent?(view.at, rx, rz, width),
            do: Map.put(Map.take(view, @fields), :key, {x, z})

      donors = donors |> Enum.map(&Map.take(&1, @fields)) |> Enum.sort_by(& &1.entity_id)
      targets = Enum.sort_by(targets, & &1.entity_id)
      %{donors: donors, targets: targets, stamp: {stamp(donors), stamp(targets)}}
    end
  end

  @doc """
  The first pair of the scene as `{donor id, target region, target uuid}`, or
  nil. The smaller stack goes; between equal stacks, the lower region's. Only
  whole donors cross (vanilla merges at most 64 items at once).
  """
  def pick(key, %{donors: donors, targets: targets}) do
    targets = Enum.group_by(targets, & &1.merge_key)

    Enum.find_value(donors, fn donor ->
      targets
      |> Map.get(donor.merge_key, [])
      |> Enum.find(fn target ->
        donor.count <= target.count and (donor.count != target.count or key < target.key) and
          donor.count + target.count <= min(target.merge_max, 64) and
          ItemMerge.near?(donor.at, target.at)
      end)
      |> case do
        nil -> nil
        target -> {donor.entity_id, target.key, target.uuid}
      end
    end)
  end

  defp stamp(views), do: Enum.map(views, &{&1.entity_id, &1.physical_revision})

  defp border?({x, _, z}, rx, rz, width),
    do:
      x < rx * width + 0.75 or x > (rx + 1) * width - 0.75 or
        z < rz * width + 0.75 or z > (rz + 1) * width - 0.75

  defp adjacent?({x, _, z}, rx, rz, width),
    do:
      x > rx * width - 0.75 and x < (rx + 1) * width + 0.75 and
        z > rz * width - 0.75 and z < (rz + 1) * width + 0.75
end
