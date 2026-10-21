defmodule Valimc.Physics.CollisionQuery do
  @moduledoc """
  Bounded geometry jobs over a `Valimc.World.View` (VMC-077e): a supervised task
  loads the chunks the boxes cover from published snapshots and runs the
  caller's geometry on that view. Nothing is fenced or re-checked afterwards;
  results grant no authority and carry no revision.
  """
  alias Valimc.Physics.BlockScan
  alias Valimc.World.View

  @timeout 250

  # Each player owns at most one job; allow its cancelled predecessor to retire.
  def worker_limit, do: Valimc.config(:max_players) * 2
  # A box encloses accepted movement, scratch travel and a possible fluid
  # escape. Individual collision scans retain their smaller 512-cell limit.
  def frame_cell_limit, do: 1024

  @doc "Run `finish` on a view of `box`. Consume the Task result/monitor or cancel it."
  def start_frame(box, finish) when is_function(finish, 1),
    do: prepare_frame(box, finish) |> launch_prepared()

  @doc "Prepare a job once; invoking the returned function starts it."
  def prepare_frame(box, finish) when is_function(finish, 1) do
    with :ok <- bounded(box),
         do: {:ok, fn -> launch([box], finish, Valimc.Workers.collision()) end}
  end

  @doc "Run `finish` on one view of up to 32 bodies' boxes."
  def start_batch_frame(boxes, finish) when is_list(boxes) and is_function(finish, 1) do
    boxes = Enum.take(boxes, 33)

    if length(boxes) in 1..32 and Enum.all?(boxes, &(bounded(&1) == :ok)),
      do: launch(boxes, finish, Valimc.ItemGeometryWorkers),
      else: {:error, :invalid_collision_batch}
  end

  def start_batch_frame(_, _), do: {:error, :invalid_collision_batch}

  # Inside the world and within the frame's cell limit.
  defp bounded({x0, y0, z0, x1, y1, z1} = box)
       when abs(x0) < 30_000_000 and abs(x1) < 30_000_000 and abs(z0) < 30_000_000 and
              abs(z1) < 30_000_000 and abs(y0) <= 1_000_000 and abs(y1) <= 1_000_000 do
    with {:ok, _} <- BlockScan.plan(box, frame_cell_limit()), do: :ok
  end

  defp bounded(_), do: {:error, :invalid_collision_query}

  defp launch_prepared({:ok, start}), do: start.()
  defp launch_prepared(error), do: error

  defp launch(boxes, finish, workers) do
    deadline = now() + @timeout

    {:ok,
     Task.Supervisor.async_nolink(
       workers,
       Valimc.Dimension.bind(fn ->
         with :ok <- gate(boxes, deadline),
              {:ok, result} <- finish.(Enum.reduce(boxes, View.new(), &View.load(&2, &1))) do
           if now() < deadline, do: {:ok, result}, else: {:error, :collision_query_timeout}
         end
       end)
     )}
  rescue
    RuntimeError -> {:error, :collision_workers_busy}
  catch
    :exit, _ -> {:error, :collision_workers_unavailable}
  end

  # Test builds can hold reads of a region (`Valimc.TestRegionGate`) to keep
  # geometry in flight, as a stalled owner did before published snapshots.
  if Application.compile_env(:valimc, :region_read_gates, false) do
    defp gate(boxes, deadline) do
      gated =
        :ets.whereis(:valimc_region_read_gates) != :undefined and
          Enum.any?(boxes, fn {x0, _, z0, x1, _, z1} ->
            for(
              x <- [x0, x1],
              z <- [z0, z1],
              do: Valimc.World.region_key(Valimc.World.chunk_key(x, z))
            )
            |> Enum.any?(&gated?/1)
          end)

      cond do
        not gated -> :ok
        now() >= deadline -> {:error, :collision_query_timeout}
        true -> Process.sleep(2) && gate(boxes, deadline)
      end
    end

    # Only the stalled incarnation's reads are held.
    defp gated?(key) do
      scoped = Valimc.Dimension.scope(key)

      case :ets.lookup(:valimc_region_read_gates, scoped) do
        [{^scoped, pid}] -> match?({^pid, _, _}, Valimc.World.Directory.lookup(key))
        _ -> false
      end
    end
  else
    defp gate(_boxes, _deadline), do: :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
