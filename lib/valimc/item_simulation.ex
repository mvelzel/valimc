defmodule Valimc.ItemSimulation do
  @moduledoc "One owner-local motion job with bounded geometry fanout over published snapshots."
  alias Valimc.ItemPhysicsQuery
  @max_inputs 256
  @fanout 8
  @deadline_ms 300

  def start(owner, epoch, token, inputs)
      when is_pid(owner) and is_reference(epoch) and is_reference(token) and is_list(inputs) do
    inputs = Enum.take(inputs, @max_inputs + 1)

    if length(inputs) in 1..@max_inputs and Enum.all?(inputs, &valid_identity?/1) and
         length(Enum.uniq_by(inputs, &Map.get(&1, :id))) == length(inputs) do
      case Task.Supervisor.start_child(
             Valimc.ItemSimulationWorkers,
             Valimc.Dimension.bind(fn ->
               Process.link(owner)
               result = resolve(inputs, now() + @deadline_ms)
               send(owner, {:resource, epoch, {:item_simulation, self(), token, result}})
             end)
           ) do
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
    loop(Enum.chunk_every(inputs, 32), %{steps: [], refused: []}, deadline)
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

      result =
        Enum.zip(tasks, results)
        |> Enum.reduce(result, fn {{task, group}, {_, reply}}, acc ->
          case reply do
            {:ok, {:ok, batch}} ->
              %{acc | steps: acc.steps ++ batch.steps, refused: acc.refused ++ batch.refused}

            _ ->
              if reply == nil, do: Task.shutdown(task, :brutal_kill)

              reason =
                case reply do
                  {:ok, {:error, reason}} -> reason
                  _ -> :item_simulation_query_failed
                end

              %{acc | refused: acc.refused ++ Enum.map(group, &{&1.id, reason})}
          end
        end)

      loop(queue, result, deadline)
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
