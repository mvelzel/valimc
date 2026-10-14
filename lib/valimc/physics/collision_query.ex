defmodule Valimc.Physics.CollisionQuery do
  @moduledoc "Supervised bounded live observations; results retain fences, not gameplay authority."
  alias Valimc.Physics.{BlockCollisions, BlockScan, CollisionContext}
  alias Valimc.World

  @timeout 250
  @max_regions 16
  @max_batches 16

  @doc "Start one query. Consume its Task result/monitor or cancel with Task.shutdown/2."
  def start(box, context \\ CollisionContext.empty()) do
    with true <- CollisionContext.valid?(context),
         {:ok, plan} <- BlockScan.plan(box),
         true <-
           Enum.all?(plan, fn {{x, y, z}, _} ->
             abs(x) < 30_000_000 and abs(z) < 30_000_000 and abs(y) <= 1_000_000
           end),
         groups =
           Enum.group_by(
             plan,
             fn {{x, _, z}, _} -> World.region_key(World.chunk_key(x, z)) end,
             fn {pos, _} -> pos end
           ),
         true <- map_size(groups) <= @max_regions,
         true <-
           Enum.sum(Enum.map(groups, fn {_, positions} -> div(length(positions) + 127, 128) end)) <=
             @max_batches do
      launch(box, context, groups)
    else
      false -> {:error, :invalid_collision_query}
      {:error, _} = error -> error
    end
  end

  defp launch(box, context, groups) do
    caller = self()
    deadline = now() + @timeout

    {:ok,
     Task.Supervisor.async_nolink(Valimc.CollisionWorkers, fn ->
       monitor = Process.monitor(caller)

       try do
         with {:ok, requests} <- request(groups),
              {:ok, observations} <- gather(requests, [], deadline, monitor, caller),
              {:ok, result} <- BlockCollisions.collect(box, observations, context) do
           if now() < deadline, do: {:ok, result}, else: {:error, :collision_query_timeout}
         end
       after
         Process.demonitor(monitor, [:flush])
       end
     end)}
  rescue
    RuntimeError -> {:error, :collision_workers_busy}
  catch
    :exit, _ -> {:error, :collision_workers_unavailable}
  end

  defp request(groups) do
    # Resolve all incarnations before enqueueing any reads; never call World.owner/1 here.
    Enum.reduce_while(groups, {:ok, []}, fn {key, positions}, {:ok, owners} ->
      case World.existing_owner(key) do
        {:ok, owner} -> {:cont, {:ok, [{key, owner, Enum.chunk_every(positions, 128)} | owners]}}
        {:error, reason} -> {:halt, {:error, {:region, key, reason}}}
      end
    end)
    |> case do
      {:ok, owners} ->
        {:ok,
         Enum.reduce(owners, :gen_server.reqids_new(), fn {key, owner, batches}, requests ->
           enqueue(requests, key, owner, batches, :any)
         end)}

      error ->
        error
    end
  end

  defp enqueue(requests, key, {pid, epoch} = owner, [batch | rest], revision) do
    label = {key, owner, batch, rest, revision}
    :gen_server.send_request(pid, {:observe_blocks, epoch, batch, revision}, label, requests)
  end

  defp gather(requests, observations, deadline, monitor, caller) do
    cond do
      now() >= deadline ->
        {:error, :collision_query_timeout}

      :gen_server.reqids_size(requests) == 0 ->
        {:ok, observations}

      true ->
        receive do
          {:DOWN, ^monitor, :process, ^caller, _} ->
            {:error, :collision_query_caller_down}

          message ->
            case :gen_server.check_response(message, requests, true) do
              {{:reply, reply}, label, remaining} ->
                next(reply, label, remaining, observations, deadline, monitor, caller)

              {{:error, _}, {key, _, _, _, _}, _} ->
                {:error, {:region, key, :region_unavailable}}

              :no_reply ->
                gather(requests, observations, deadline, monitor, caller)
            end
        after
          max(deadline - now(), 0) -> {:error, :collision_query_timeout}
        end
    end
  end

  defp next(
         {:ok, %{owner: owner, region: key, revision: revision, blocks: blocks} = observation},
         {key, owner, batch, rest, expected},
         requests,
         observations,
         deadline,
         monitor,
         caller
       )
       when is_integer(revision) and revision >= 0 and is_map(blocks) do
    cond do
      expected != :any and expected != revision ->
        {:error, {:region, key, :stale_revision}}

      map_size(blocks) != length(batch) or Enum.any?(batch, &(not Map.has_key?(blocks, &1))) ->
        {:error, {:region, key, :invalid_block_observation}}

      true ->
        requests =
          if rest == [], do: requests, else: enqueue(requests, key, owner, rest, revision)

        gather(requests, [observation | observations], deadline, monitor, caller)
    end
  end

  defp next({:error, reason}, {key, _, _, _, _}, _, _, _, _, _),
    do: {:error, {:region, key, reason}}

  defp next(_, {key, _, _, _, _}, _, _, _, _, _),
    do: {:error, {:region, key, :invalid_block_observation}}

  defp now, do: System.monotonic_time(:millisecond)
end
