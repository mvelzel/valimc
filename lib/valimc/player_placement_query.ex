defmodule Valimc.PlayerPlacementQuery do
  @moduledoc "Bounded placement preparation; a sampled plan grants no player or world authority."
  alias Valimc.Physics.Placement
  alias Valimc.World
  alias Valimc.World.{BlockBatch, Region}
  @timeout 250

  def start(item, request) do
    with {:ok, _} <- Placement.candidate(item, 0, 0, request) do
      deadline = now() + @timeout

      {:ok,
       Task.Supervisor.async_nolink(Valimc.CollisionWorkers, fn ->
         prepare(item, request, deadline)
       end)}
    end
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  defp prepare(item, request, deadline) do
    positions = Enum.uniq([request.position, Placement.adjacent(request)])
    groups = Enum.group_by(positions, fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end)

    # The first write lane deliberately covers one block owner. Cross-owner plans
    # require a separate consistency contract before they can become mutations.
    with [{key, positions}] <- Map.to_list(groups),
         {:ok, owner} <- World.existing_owner(key),
         {:ok, observed} <- Region.observe_blocks(owner, positions),
         {:ok, candidate} <-
           Placement.candidate(
             item,
             observed.blocks[request.position],
             observed.blocks[Placement.adjacent(request)],
             request
           ),
         {:ok, batch} <- BlockBatch.prepare(%{candidate.position => candidate.state}),
         {:ok, _} <- Region.observe_blocks(owner, [], observed.revision),
         true <- World.existing_owner(key) == {:ok, owner} and now() < deadline do
      {:ok,
       %{
         owner: owner,
         region: key,
         revision: observed.revision,
         candidate: candidate,
         batch: batch,
         deadline: deadline
       }}
    else
      groups when is_list(groups) -> {:error, :cross_owner_placement}
      false -> {:error, :expired_placement}
      error -> error
    end
  catch
    :exit, _ -> {:error, :placement_region_unavailable}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
