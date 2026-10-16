defmodule Valimc.ItemSimulation do
  @moduledoc "One owner-local motion job with bounded geometry fanout; results retain commit fences."
  alias Valimc.ItemPhysicsQuery
  @max_inputs 256
  @fanout 8
  @deadline_ms 300

  def start(owner, epoch, token, inputs)
      when is_pid(owner) and is_reference(epoch) and is_reference(token) and is_list(inputs) do
    inputs = Enum.take(inputs, @max_inputs + 1)

    if length(inputs) in 1..@max_inputs and Enum.all?(inputs, &valid_identity?/1) and
         length(Enum.uniq_by(inputs, &Map.get(&1, :id))) == length(inputs) do
      case Task.Supervisor.start_child(Valimc.ItemSimulationWorkers, fn ->
             Process.link(owner)
             result = resolve(inputs, now() + @deadline_ms)
             send(owner, {:resource, epoch, {:item_simulation, self(), token, result}})
           end) do
        {:ok, worker} -> {:ok, %{worker: worker, monitor: Process.monitor(worker), token: token}}
        {:error, _} -> {:error, :item_simulation_busy}
      end
    else
      {:error, :invalid_item_simulation}
    end
  catch
    :exit, _ -> {:error, :item_simulation_unavailable}
  end

  def start(_, _, _, _), do: {:error, :invalid_item_simulation}

  defp resolve(inputs, deadline) do
    loop(Enum.chunk_every(inputs, 32), %{steps: [], refused: [], fences: %{}}, deadline)
  end

  defp loop([], result, _), do: {:ok, result}

  defp loop(queue, result, deadline) do
    if now() >= deadline do
      refused = for group <- queue, input <- group, do: {input.id, :item_simulation_timeout}
      {:ok, %{result | refused: result.refused ++ refused}}
    else
      {tasks, queue, refused} = launch(queue, [], [], deadline)
      result = %{result | refused: result.refused ++ refused}

      results =
        tasks
        |> Enum.map(&elem(&1, 0))
        |> Task.yield_many(max(deadline - now(), 0))

      {result, conflict} =
        Enum.zip(tasks, results)
        |> Enum.reduce({result, false}, fn {{task, group}, {_, reply}}, {acc, conflict} ->
          case reply do
            {:ok, {:ok, batch}} ->
              clash =
                Enum.any?(batch.fences, fn {key, fence} ->
                  Map.has_key?(acc.fences, key) and acc.fences[key] != fence
                end)

              {%{
                 acc
                 | steps: acc.steps ++ batch.steps,
                   refused: acc.refused ++ batch.refused,
                   fences: Map.merge(acc.fences, batch.fences)
               }, conflict or clash}

            _ ->
              if reply == nil, do: Task.shutdown(task, :brutal_kill)

              reason =
                case reply do
                  {:ok, {:error, reason}} -> reason
                  _ -> :item_simulation_query_failed
                end

              {%{acc | refused: acc.refused ++ Enum.map(group, &{&1.id, reason})}, conflict}
          end
        end)

      if conflict,
        do: {:error, :conflicting_item_frame},
        else: loop(queue, result, deadline)
    end
  end

  defp launch(queue, tasks, refused, _deadline)
       when length(tasks) == @fanout or queue == [],
       do: {Enum.reverse(tasks), queue, Enum.reverse(refused)}

  defp launch([group | rest] = queue, tasks, refused, deadline) do
    if now() >= deadline do
      {Enum.reverse(tasks), queue, Enum.reverse(refused)}
    else
      case ItemPhysicsQuery.start(group) do
        {:ok, task} ->
          launch(rest, [{task, group} | tasks], refused, deadline)

        {:error, :block_scan_limit} when length(group) > 1 ->
          {a, b} = Enum.split(group, div(length(group), 2))
          launch([a, b | rest], tasks, refused, deadline)

        {:error, reason} ->
          launch(rest, tasks, Enum.reduce(group, refused, &[{&1.id, reason} | &2]), deadline)
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp valid_identity?(%{id: id, revision: revision}),
    do: is_integer(id) and id in 1..2_147_483_647 and is_integer(revision) and revision > 0

  defp valid_identity?(_), do: false
end
