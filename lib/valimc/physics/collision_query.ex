defmodule Valimc.Physics.CollisionQuery do
  @moduledoc "Supervised bounded live observations; results retain fences, not gameplay authority."
  alias Valimc.Physics.{BlockCollisions, BlockScan, CollisionContext}
  alias Valimc.World
  alias Valimc.World.{BlockSnapshot, Directory}

  @timeout 250
  @max_regions 16
  @max_batches 16

  # Each player owns at most one job; allow its cancelled predecessor to retire.
  # Owner observation waits yield to BEAM, whose schedulers bound CPU execution.
  def worker_limit, do: Valimc.config(:max_players) * 2
  # A frame encloses accepted movement, scratch travel and a possible fluid
  # escape. Individual collision scans retain their smaller 512-cell limit.
  def frame_cell_limit, do: 1024

  @doc "Start one query. Consume its Task result/monitor or cancel with Task.shutdown/2."
  def start(box, context \\ CollisionContext.empty()),
    do:
      prepare(box, context, &BlockCollisions.collect(box, &1, context), false, false)
      |> launch_prepared()

  @doc "Run bounded geometry work on a sampled frame, then recheck every source revision."
  def start_frame(box, context, finish) when is_function(finish, 1),
    do: prepare(box, context, finish, true, false) |> launch_prepared()

  @doc "Authoritative movement may request cold admission; a loading source still fails closed."
  def start_movement_frame(box, context, finish) when is_function(finish, 1),
    do: prepare_movement_frame(box, context, finish) |> launch_prepared()

  @doc "Prepare bounded geometry once; invoking the returned function resolves fresh owners and starts a job."
  def prepare_movement_frame(box, context, finish) when is_function(finish, 1),
    do: prepare(box, context, finish, true, true)

  @doc "Sample up to32 disjoint bodies in one fenced job, without scanning the space between them."
  def start_batch_frame(boxes, finish) when is_list(boxes) and is_function(finish, 1) do
    boxes = Enum.take(boxes, 33)

    if length(boxes) in 1..32 do
      Enum.reduce_while(boxes, {:ok, MapSet.new()}, fn box, {:ok, positions} ->
        with {:ok, plan} <- BlockScan.plan(box, frame_cell_limit()),
             next = Enum.reduce(plan, positions, fn {pos, _}, acc -> MapSet.put(acc, pos) end),
             true <- MapSet.size(next) <= frame_cell_limit() do
          {:cont, {:ok, next}}
        else
          false -> {:halt, {:error, :block_scan_limit}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, positions} ->
          prepare_positions(Enum.sort(positions), finish, true, true, Valimc.ItemGeometryWorkers)

        error ->
          error
      end
      |> launch_prepared()
    else
      {:error, :invalid_collision_batch}
    end
  end

  def start_batch_frame(_, _), do: {:error, :invalid_collision_batch}

  defp launch_prepared({:ok, start}), do: start.()
  defp launch_prepared(error), do: error

  defp prepare(box, context, finish, verify, admit) do
    with true <- CollisionContext.valid?(context),
         {:ok, plan} <- BlockScan.plan(box, if(verify, do: frame_cell_limit(), else: 512)) do
      prepare_positions(Enum.map(plan, &elem(&1, 0)), finish, verify, admit)
    else
      false -> {:error, :invalid_collision_query}
      error -> error
    end
  end

  defp prepare_positions(positions, finish, verify, admit, workers \\ nil) do
    with true <-
           Enum.all?(positions, fn {x, y, z} ->
             abs(x) < 30_000_000 and abs(z) < 30_000_000 and abs(y) <= 1_000_000
           end),
         groups =
           Enum.group_by(
             positions,
             fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end
           ),
         true <- map_size(groups) <= @max_regions,
         true <-
           Enum.sum(Enum.map(groups, fn {_, positions} -> div(length(positions) + 127, 128) end)) <=
             @max_batches do
      {:ok,
       fn -> launch(groups, finish, verify, admit, workers || Valimc.Workers.collision()) end}
    else
      false -> {:error, :invalid_collision_query}
      {:error, _} = error -> error
    end
  end

  # Reads come from each owner's published chunk snapshots (`BlockSnapshot`); no
  # owner mailbox is involved. Verification re-checks every source fence.
  defp launch(groups, finish, verify, admit, workers) do
    deadline = now() + @timeout

    {:ok,
     Task.Supervisor.async_nolink(workers, fn ->
       with {:ok, sources} <- resolve(groups, admit),
            {:ok, observations} <- observe(sources, deadline),
            {:ok, result} <- finish.(observations),
            :ok <- verify_frame(verify, observations, sources) do
         if now() < deadline, do: {:ok, result}, else: {:error, :collision_query_timeout}
       end
     end)}
  rescue
    RuntimeError -> {:error, :collision_workers_busy}
  catch
    :exit, _ -> {:error, :collision_workers_unavailable}
  end

  defp resolve(groups, admit) do
    Enum.reduce_while(groups, {:ok, []}, fn {key, positions}, {:ok, sources} ->
      case source(key, admit) do
        {:ok, owner, table} -> {:cont, {:ok, [{key, owner, table, positions} | sources]}}
        {:error, reason} -> {:halt, {:error, {:region, key, reason}}}
      end
    end)
  end

  defp source(key, admit) do
    case published(key) do
      {:error, _} when admit ->
        # Disk loading stays in its resource owner; a loading source fails closed.
        with {:ok, _} <- World.region(key), do: published(key)

      result ->
        result
    end
  end

  defp published(key) do
    with {:ok, {pid, epoch} = owner} <- World.existing_owner(key),
         {^pid, _, %{epoch: ^epoch, items: table}} <- Directory.lookup(key) do
      {:ok, owner, table}
    else
      {:error, _} = error -> error
      _ -> {:error, :region_unavailable}
    end
  end

  # Test builds can hold reads of a region (`Valimc.TestRegionGate`) to keep
  # geometry in flight, as a stalled owner did before published snapshots.
  if Application.compile_env(:valimc, :region_read_gates, false) do
    defp gate(key, pid, deadline) do
      cond do
        :ets.whereis(:valimc_region_read_gates) == :undefined -> :ok
        :ets.lookup(:valimc_region_read_gates, key) != [{key, pid}] -> :ok
        now() >= deadline -> {:error, :collision_query_timeout}
        true -> Process.sleep(2) && gate(key, pid, deadline)
      end
    end
  else
    defp gate(_key, _pid, _deadline), do: :ok
  end

  defp observe(sources, deadline) do
    Enum.reduce_while(sources, {:ok, []}, fn {key, {pid, epoch} = owner, table, positions},
                                             {:ok, acc} ->
      with :ok <- gate(key, pid, deadline),
           result <- BlockSnapshot.read(table, epoch, positions) do
        result
      end
      |> case do
        {:ok, revision, blocks} ->
          # One consistent revision, delivered in the bounded 128-block observation shape.
          batches =
            for batch <- Enum.chunk_every(positions, 128),
                do: %{
                  owner: owner,
                  region: key,
                  revision: revision,
                  blocks: Map.take(blocks, batch)
                }

          {:cont, {:ok, batches ++ acc}}

        {:error, :collision_query_timeout} = timeout ->
          {:halt, timeout}

        {:error, reason} ->
          {:halt, {:error, {:region, key, reason}}}
      end
    end)
  end

  defp verify_frame(false, _, _), do: :ok

  defp verify_frame(true, observations, sources) do
    tables = Map.new(sources, fn {key, _, table, _} -> {key, table} end)

    Enum.reduce_while(observations, :ok, fn %{region: key, owner: {_, epoch} = owner} = o, :ok ->
      cond do
        World.existing_owner(key) != {:ok, owner} ->
          {:halt, {:error, {:region, key, :region_unavailable}}}

        not BlockSnapshot.current?(tables[key], epoch, o.revision) ->
          {:halt, {:error, {:region, key, :stale_revision}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
