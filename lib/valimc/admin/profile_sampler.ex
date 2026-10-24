defmodule Valimc.Admin.ProfileSampler do
  @moduledoc """
  Bounded, non-tracing BEAM stack observations. Reductions rank processes;
  observed stacks count sightings, never pretend to be CPU nanoseconds.
  Native frames can be observed at the BEAM boundary, not inside Rust.
  """
  @limit 4096
  @batch 128
  @stacks 4096
  @keys [
    :registered_name,
    :initial_call,
    :status,
    :current_stacktrace,
    :reductions,
    :memory,
    :message_queue_len
  ]

  def new(options) do
    %{
      options: options,
      queue: [],
      previous: %{},
      processes: %{},
      stacks: %{},
      rounds: 0,
      observations: 0,
      dropped: 0,
      population: 0,
      groups: %{},
      cursor: 0,
      visited: 0,
      discovery: nil
    }
  end

  def sample(state, now) do
    state =
      if state.discovery == nil or now >= state.discovery do
        pids = Enum.reject(:erlang.processes(), &(&1 == self()))
        # Rotate the discovery window as well as the batch; large nodes are not
        # permanently sampled from the same first 4096 processes.
        {queue, offset} = window(pids, state.cursor, state.visited)
        previous = Map.take(state.previous, queue)

        %{
          state
          | queue: queue,
            previous: previous,
            population: length(pids),
            discovery: now + 1000,
            groups: groups(),
            cursor: offset,
            visited: 0
        }
      else
        state
      end

    {batch, rest} = Enum.split(state.queue, @batch)

    state = %{
      state
      | queue: rest ++ batch,
        rounds: state.rounds + 1,
        visited: min(@limit, state.visited + length(batch))
    }

    Enum.reduce(batch, state, &observe/2)
  end

  @doc false
  def window(pids, cursor, visited) do
    # Advance by unique coverage, not total passes (which can wrap within the
    # window). Otherwise a population sharing a divisor with the pass count can
    # leave entire ranges unseen. Sparse sampling must still advance each time.
    offset = rem(cursor + min(visited, @limit), max(length(pids), 1))
    queue = (Enum.drop(pids, offset) ++ Enum.take(pids, offset)) |> Enum.take(@limit)
    {queue, offset}
  end

  defp observe(pid, state) do
    case Process.info(pid, @keys) do
      nil ->
        state

      info ->
        reductions = info[:reductions]
        delta = max(0, reductions - Map.get(state.previous, pid, reductions))
        state = %{state | previous: Map.put(state.previous, pid, reductions)}
        stack = Enum.take(info[:current_stacktrace], 48)
        frames = Enum.map(Enum.reverse(stack), &frame/1)
        name = Map.get(state.groups, pid) || label(info, stack)
        selected = state.options.process == "*" or String.contains?(name, state.options.process)

        if selected do
          row = %{
            pid: inspect(pid),
            name: name,
            reductions: delta,
            memory: info[:memory],
            mailbox: info[:message_queue_len],
            status: to_string(info[:status])
          }

          previous = Map.get(state.processes, pid, %{reductions: 0})
          row = %{row | reductions: previous.reductions + delta}

          processes =
            if map_size(state.processes) < @limit or Map.has_key?(state.processes, pid),
              do: Map.put(state.processes, pid, row),
              else: state.processes

          state = %{state | processes: processes}

          if frames != [] and
               (state.options.include_waiting or info[:status] in [:running, :runnable]) do
            key = {name, frames}

            if map_size(state.stacks) < @stacks or Map.has_key?(state.stacks, key) do
              %{
                state
                | stacks: Map.update(state.stacks, key, 1, &(&1 + 1)),
                  observations: state.observations + 1
              }
            else
              %{state | dropped: state.dropped + 1}
            end
          else
            state
          end
        else
          state
        end
    end
  end

  defp label(info, stack) do
    case info[:registered_name] do
      name when is_atom(name) ->
        inspect(name)

      _ ->
        case Enum.find(stack, fn {module, _, _, _} ->
               String.starts_with?(Atom.to_string(module), "Elixir.Valimc.")
             end) do
          {module, _, _, _} -> inspect(module)
          _ -> info[:initial_call] |> elem(0) |> inspect()
        end
    end
  end

  defp groups do
    # The region registry has one entry per section, potentially hundreds per
    # owner. Tick publications have one row per owner, so discovery stays small.
    regions =
      :ets.select(Valimc.Data.ProfileTicks, [{{:"$1", :_, :_, :_, :_, :_, :_}, [], [:"$1"]}])

    players = :ets.select(Valimc.Player.PlayerList, [{{:"$1", :_}, [], [:"$1"]}])

    Map.merge(
      Map.new(regions, &{&1, "Valimc.World.Region"}),
      Map.new(players, &{&1, "Valimc.Net.Connection"})
    )
  end

  defp frame({module, function, arity, _location}) do
    arity = if is_list(arity), do: length(arity), else: arity
    "#{inspect(module)}.#{function}/#{arity}"
  end

  def export(state) do
    %{
      observations: state.observations,
      rounds: state.rounds,
      dropped: state.dropped,
      population: state.population,
      process_limit: @limit,
      batch: @batch,
      processes: state.processes |> Map.values() |> Enum.sort_by(&(-&1.reductions)),
      stacks:
        Enum.map(state.stacks, fn {{name, frames}, count} ->
          %{name: name, frames: frames, count: count}
        end)
    }
  end
end
