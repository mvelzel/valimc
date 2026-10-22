defmodule Valimc.PlayerPlacementQuery do
  @moduledoc "Bounded placement preparation; a sampled plan grants no player or world authority."
  alias Valimc.Physics.Placement
  alias Valimc.Physics.{CollisionContext, Kernel}
  alias Valimc.World
  alias Valimc.World.{BlockBatch, Region}
  # A plan's budget; tests on a loaded host scale it (`owner_call_scale`, VMC-073).
  defp timeout, do: 250 * Valimc.config(:owner_call_scale)
  @placement %CollisionContext{kind: :entity, placement: true}

  def start(item, request) do
    with {:ok, _} <- Placement.candidate(item, 0, 0, request) do
      deadline = now() + timeout()

      {:ok,
       Task.Supervisor.async_nolink(
         Valimc.Workers.actions(),
         Valimc.Dimension.bind(fn ->
           prepare(item, request, deadline)
         end)
       )}
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
     Task.Supervisor.async_nolink(
       Valimc.TransferWorkers,
       Valimc.Dimension.bind(fn ->
         outcome =
           case prepare(item, request, now() + timeout()) do
             {:ok, plan} ->
               if admitted?(plan, grant, expires) do
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

         with {:ok, after_ack} <- correct(request, connection), do: {:ok, outcome, after_ack}
       end)
     )}
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  @doc "Bounded creative destruction and correction; disk acknowledgment never blocks the player owner."
  def start_destroy(position, eye, expires) do
    connection = self()

    {:ok,
     Task.Supervisor.async_nolink(
       Valimc.TransferWorkers,
       Valimc.Dimension.bind(fn ->
         {x, _, z} = position
         key = World.region_key(World.chunk_key(x, z))

         with {:ok, owner} <- World.existing_owner(section(key)),
              {:ok, observed} <- Region.observe_blocks(owner, [position]) do
           outcome =
             if now() < expires and
                  Valimc.PlayerInteraction.within_block?(:creative, eye, position),
                do: Region.destroy_block(owner, observed.fence, position, expires),
                else: {:refused, :expired_destruction}

           with :ok <- Region.correct_blocks(owner, [position], connection),
                {:ok, update} <- Region.block_entity_update(owner, position),
                do: {:ok, outcome, List.wrap(update)}
         end
       end)
     )}
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  @doc "Reserve a prepared survival context; this job never consumes inventory or places a block."
  def start_survival(item, request, grant, expires) do
    connection = self()

    {:ok,
     Task.Supervisor.async_nolink(
       Valimc.Workers.actions(),
       Valimc.Dimension.bind(fn ->
         result =
           with {:ok, plan} <- prepare(item, request, now() + timeout()),
                true <- admitted?(plan, grant, expires),
                {:ok, reservation} <-
                  Region.reserve_placement(plan.owner, plan.revision, plan.expected) do
             reservation = Map.merge(reservation, %{owner: plan.owner, key: plan.region})

             if now() < expires,
               do: {:reserved, Map.merge(reservation, %{candidate: plan.candidate})},
               else:
                 (
                   Region.release_placement(plan.owner, reservation.permit)
                   {:refused, :expired_placement}
                 )
           else
             false -> {:refused, :player_admission}
             error -> error
           end

         case result do
           {:reserved, _} ->
             result

           outcome ->
             with {:ok, after_ack} <- correct(request, connection), do: {:ok, outcome, after_ack}
         end
       end)
     )}
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  def start_correction(request, reservation) do
    connection = self()

    {:ok,
     Task.Supervisor.async_nolink(
       Valimc.Workers.actions(),
       Valimc.Dimension.bind(fn ->
         if reservation do
           try do
             Region.release_placement(reservation.owner, reservation.permit)
           catch
             :exit, _ -> :ok
           end
         end

         with {:ok, after_ack} <- correct(request, connection), do: {:ok, :corrected, after_ack}
       end)
     )}
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  defp admitted?(_plan, nil, _expires), do: false

  defp admitted?(plan, grant, expires) do
    {x, _, z} = plan.candidate.position

    now() < expires and MapSet.member?(grant.chunks, World.chunk_key(x, z)) and
      unobstructed?(plan.candidate, grant.boxes)
  end

  # `CollisionContext.placementContext`: scaffolding and powder snow place freely.
  defp unobstructed?(%{state: state, position: position}, bodies),
    do: not Kernel.obstructs?(state, position, @placement, bodies)

  # The routing key of section `key` of the dimension this task was bound to.
  defp section(key), do: World.section(Valimc.Dimension.current(), key, :section)

  # Corrections go out now; imported block entity data (VMC-021e1) is returned
  # to follow the acknowledgement, since the client drops block entity data that
  # arrives while its prediction for the sequence is pending.
  defp correct(request, connection) do
    [request.position, Placement.adjacent(request)]
    |> Enum.uniq()
    |> Enum.group_by(fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end)
    |> Enum.reduce_while({:ok, []}, fn {key, positions}, {:ok, packets} ->
      with {:ok, owner} <- World.existing_owner(section(key)),
           :ok <- Region.correct_blocks(owner, positions, connection) do
        updates =
          for position <- positions,
              {:ok, update} = Region.block_entity_update(owner, position),
              update != nil,
              do: update

        {:cont, {:ok, packets ++ updates}}
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
         {:ok, owner} <- World.existing_owner(section(key)),
         {:ok, observed} <- Region.observe_blocks(owner, positions),
         {:ok, candidate} <-
           candidate(
             item,
             observed.blocks[request.position],
             observed.blocks[Placement.adjacent(request)],
             request
           ),
         {:ok, candidate} <- surviving(owner, candidate),
         {:ok, batch} <- BlockBatch.prepare(%{candidate.position => candidate.state}),
         :ok <- isolated_chest(owner, key, candidate, observed.fence),
         {:ok, _} <- Region.observe_blocks(owner, [], observed.fence),
         true <- World.existing_owner(section(key)) == {:ok, owner} and now() < deadline do
      {:ok,
       %{
         owner: owner,
         region: key,
         revision: observed.fence,
         candidate: candidate,
         expected: observed.blocks,
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

  # A creative block item without modelled placement (VMC-077a): its block on
  # a replaceable block beside the clicked face, in the first of its candidate
  # states that can survive there (`Placement.creative_states/4`).
  defp candidate({:block, block}, clicked, adjacent, request) do
    with true <- Placement.replaceable?(adjacent) || {:error, :occupied},
         [_ | _] = states <-
           Placement.creative_states(block, clicked, adjacent, request) do
      {:ok, %{position: Placement.adjacent(request), states: states, replace_clicked: false}}
    else
      [] -> {:error, :cannot_survive}
      error -> error
    end
  end

  defp candidate(item, clicked, adjacent, request),
    do: Placement.candidate(item, clicked, adjacent, request)

  defp surviving(owner, %{states: states} = candidate) do
    with {:ok, state} <- Region.placement_state(owner, candidate.position, states),
         do: {:ok, candidate |> Map.delete(:states) |> Map.put(:state, state)}
  end

  defp surviving(_owner, candidate), do: {:ok, candidate}

  defp isolated_chest(owner, key, candidate, revision) do
    if Valimc.Block.Chest.single?(candidate.state) do
      neighbors = Valimc.ChestPlacement.neighbors(candidate.position)

      if Enum.all?(neighbors, fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) == key end) do
        with {:ok, observed} <- Region.observe_blocks(owner, neighbors, revision),
             false <-
               Enum.any?(observed.blocks, fn {_, state} -> Valimc.Block.Chest.ordinary?(state) end),
             do: :ok,
             else: (
               true -> {:error, :adjacent_chest}
               error -> error
             )
      else
        {:error, :cross_owner_chest}
      end
    else
      :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
