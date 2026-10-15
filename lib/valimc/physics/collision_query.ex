defmodule Valimc.Physics.CollisionQuery do
  @moduledoc "Supervised bounded live observations; results retain fences, not gameplay authority."
  alias Valimc.Physics.{BlockCollisions, BlockScan, CollisionContext}
  alias Valimc.World

  @timeout 250
  @max_regions 16
  @max_batches 16

  @doc "Start one query. Consume its Task result/monitor or cancel with Task.shutdown/2."
  def start(box, context \\ CollisionContext.empty()),
    do: prepare(box, context, &BlockCollisions.collect(box, &1, context), false, false)

  @doc "Run bounded geometry work on a sampled frame, then recheck every source revision."
  def start_frame(box, context, finish) when is_function(finish, 1),
    do: prepare(box, context, finish, true, false)

  @doc "Authoritative movement may request cold admission; a loading source still fails closed."
  def start_movement_frame(box, context, finish) when is_function(finish, 1),
    do: prepare(box, context, finish, true, true)

  defp prepare(box, context, finish, verify, admit) do
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
      launch(groups, finish, verify, admit)
    else
      false -> {:error, :invalid_collision_query}
      {:error, _} = error -> error
    end
  end

  defp launch(groups, finish, verify, admit) do
    caller = self()
    deadline = now() + @timeout

    {:ok,
     Task.Supervisor.async_nolink(Valimc.CollisionWorkers, fn ->
       monitor = Process.monitor(caller)

       try do
         with {:ok, requests} <- request(groups, admit),
              {:ok, observations} <- gather(requests, [], deadline, monitor, caller),
              {:ok, result} <- finish.(observations),
              :ok <- verify_frame(verify, observations, deadline, monitor, caller) do
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

  defp verify_frame(false, _, _, _, _), do: :ok

  defp verify_frame(true, observations, deadline, monitor, caller) do
    observations
    |> Enum.uniq_by(& &1.region)
    |> Enum.reduce_while({:ok, :gen_server.reqids_new()}, fn observation, {:ok, requests} ->
      %{region: key, owner: owner, revision: revision} = observation

      if World.existing_owner(key) == {:ok, owner} do
        {:cont, {:ok, enqueue(requests, key, owner, [[]], revision)}}
      else
        {:halt, {:error, {:region, key, :region_unavailable}}}
      end
    end)
    |> case do
      {:ok, requests} ->
        case gather(requests, [], deadline, monitor, caller) do
          {:ok, _} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp request(groups, admit) do
    # Resolve all incarnations before enqueueing any reads; never call World.owner/1 here.
    Enum.reduce_while(groups, {:ok, []}, fn {key, positions}, {:ok, owners} ->
      case source(key, admit) do
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

  defp source(key, admit) do
    case World.existing_owner(key) do
      {:error, _} when admit ->
        # Disk loading stays in its resource owner. Never await World.owner/1
        # here: the player deadline can cancel this worker even during admission.
        with {:ok, _} <- World.region(key), do: World.existing_owner(key)

      result ->
        result
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
