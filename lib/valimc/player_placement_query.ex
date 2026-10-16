defmodule Valimc.PlayerPlacementQuery do
  @moduledoc "Bounded placement preparation; a sampled plan grants no player or world authority."
  alias Valimc.Physics.Placement
  alias Valimc.Physics.{BlockShapes, Box, Shape}
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

  @doc "Execute one already-admitted creative command, then order its corrections on block owners."
  def start_creative(item, request, grant, expires) do
    connection = self()

    {:ok,
     Task.Supervisor.async_nolink(Valimc.CollisionWorkers, fn ->
       outcome =
         case prepare(item, request, now() + @timeout) do
           {:ok, plan} ->
             if grant != nil and now() < expires and
                  MapSet.member?(
                    grant.chunks,
                    World.chunk_key(
                      elem(plan.candidate.position, 0),
                      elem(plan.candidate.position, 2)
                    )
                  ) and
                  unobstructed?(plan.candidate, grant.box) do
               Region.place_block(
                 plan.owner,
                 plan.revision,
                 plan.batch,
                 min(plan.deadline, expires)
               )
             else
               {:refused, :player_admission}
             end

           {:error, reason} ->
             {:refused, reason}
         end

       with :ok <- correct(request, connection), do: {:ok, outcome}
     end)}
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  defp unobstructed?(%{state: state, position: position}, body) do
    with {:ok, shape} <- BlockShapes.fetch(state) do
      shape = Shape.move(shape, position)
      not Enum.any?(shape.boxes, &Box.intersects?(body, &1))
    else
      _ -> false
    end
  end

  defp correct(request, connection) do
    [request.position, Placement.adjacent(request)]
    |> Enum.uniq()
    |> Enum.group_by(fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end)
    |> Enum.reduce_while(:ok, fn {key, positions}, :ok ->
      with {:ok, owner} <- World.existing_owner(key),
           :ok <- Region.correct_blocks(owner, positions, connection) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
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
