defmodule Valimc.World.RegionGeneration do
  @moduledoc """
  Generation of a region's absent chunks (VMC-075), run by its owner.

  A region of a generated world loads without generating: the chunks its log
  has no column for are absent. Loading tickets (`Valimc.World.Tickets`) say
  which chunks are wanted and how far from their center; calls that need an
  absent chunk want it first (`urgent/2`). The owner tells its dimension's
  generation scheduler (`Valimc.Worldgen.Scheduler`, VMC-077n) which absent
  chunks it wants, each at its smallest squared distance to a ticket's center
  (urgent ones at -1), whenever that changes, and reports the chunks it has
  when it loads. The scheduler sends each chunk once it is full, lit alone
  where it was generated (VMC-077c).

  A chunk is installed when it arrives and its column image joins the
  owner's next frame (`RegionStorage`, VMC-077f): its column adopts its light
  and light crosses its faces, its block entities and ticks are added, its
  snapshot published, neighbours' rings and served chunks' light updated, and
  the calls that waited for it run again. The scheduler drops its proto state
  once that frame is durable. A chunk whose generation failed stays absent
  and its waiting calls fail.

  Until then an absent chunk is like a chunk of an unloaded neighbour region:
  the owner's block reads see nothing there and edits of it are refused.
  """
  require Logger
  alias Valimc.World
  alias Valimc.World.{BlockEntities, BlockSnapshot, Blocks, RegionData, Spec}
  alias Valimc.World.{RegionStorage, ScheduledTicks, Tickets}
  alias Valimc.Worldgen.{FullChunk, Scheduler}

  @max_deferred 1024

  defstruct world: nil,
            dimension: nil,
            generated: false,
            absent: MapSet.new(),
            urgent: MapSet.new(),
            failed: MapSet.new(),
            scheduler: nil,
            sent: %{},
            deferred: %{},
            deferred_count: 0,
            retry: nil,
            failures: 0

  @doc "Region `key`'s chunks, Z outer and X inner."
  def chunks_of({rx, rz}) do
    size = Valimc.config(:region_size)

    for cz <- (rz * size)..(rz * size + size - 1),
        cx <- (rx * size)..(rx * size + size - 1),
        do: {cx, cz}
  end

  @doc "The generation state of region `key` whose log holds column `images`."
  def new(key, images) do
    path = Valimc.config(:world_path, key)
    world = Spec.fetch(path)
    dimension = Valimc.Dimension.current()
    {present, absent} = Enum.split_with(chunks_of(key), &Map.has_key?(images, &1))

    case Spec.generation(world, dimension) do
      nil ->
        %__MODULE__{}

      {:error, reason} when absent != [] ->
        exit({:generation_unavailable, reason})

      {:error, _} ->
        %__MODULE__{}

      {:ok, _} ->
        # Neighbours wanted later must know these are full (VMC-077n).
        if Spec.decorated?(world, dimension), do: Scheduler.present(path, dimension, present)

        %__MODULE__{
          world: path,
          dimension: dimension,
          generated: true,
          absent: MapSet.new(absent)
        }
    end
  end

  @doc "Whether `chunk` is not generated yet."
  def absent?(%__MODULE__{absent: absent}, chunk), do: MapSet.member?(absent, chunk)

  @doc "Whether any of `chunks` is not generated yet."
  def any_absent?(%__MODULE__{absent: absent}, chunks),
    do: map_size(absent.map) > 0 and Enum.any?(chunks, &MapSet.member?(absent, &1))

  @doc "Absent `chunks` some call needs: wanted before anything else."
  def urgent(state, chunks) do
    gen = state.generation

    case Enum.filter(chunks, &absent?(gen, &1)) do
      [] -> state
      missing -> pump(%{state | generation: %{gen | urgent: Enum.into(missing, gen.urgent)}})
    end
  end

  @doc """
  Run `message` from `from` again once `chunk` is installed, wanting it now;
  `{:reply, {:error, {:retry, :chunk_generating}}, state}` when too many calls
  wait, `{:error, {:reject, :chunk_generation_failed}}` when its generation
  failed.
  """
  def defer(state, chunk, message, from) do
    gen = state.generation

    cond do
      MapSet.member?(gen.failed, chunk) ->
        {:reply, Valimc.Error.reject(:chunk_generation_failed), state}

      gen.deferred_count >= @max_deferred ->
        {:reply, Valimc.Error.retry(:chunk_generating), state}

      true ->
        deferred = Map.update(gen.deferred, chunk, [{message, from}], &[{message, from} | &1])
        gen = %{gen | deferred: deferred, deferred_count: gen.deferred_count + 1}
        {:noreply, urgent(%{state | generation: gen}, [chunk])}
    end
  end

  ## Wants

  @doc """
  The absent chunks of loading `tickets` and urgent calls, each at its
  smallest squared distance to a ticket's center (urgent ones at -1).
  """
  def wanted(%__MODULE__{} = gen, %Tickets{} = tickets) do
    Enum.map(gen.urgent, &{&1, -1})
    |> Enum.concat(
      for {center, set} <- Tickets.loading(tickets), {x, z} = chunk <- set do
        case center do
          {cx, cz} -> {chunk, (x - cx) * (x - cx) + (z - cz) * (z - cz)}
          nil -> {chunk, 0}
        end
      end
    )
    |> Enum.reject(fn {chunk, _} ->
      not absent?(gen, chunk) or MapSet.member?(gen.failed, chunk)
    end)
    |> Enum.reduce(%{}, fn {chunk, priority}, acc ->
      Map.update(acc, chunk, priority, &min(&1, priority))
    end)
  end

  @doc "Tell the scheduler what the region wants now, if that changed."
  def pump(%{generation: %{generated: false}} = state), do: state
  def pump(%{generation: %{retry: retry}} = state) when retry != nil, do: state

  def pump(state) do
    gen = state.generation
    wanted = wanted(gen, state.tickets)

    if wanted == gen.sent and (gen.scheduler != nil or wanted == %{}) do
      state
    else
      case Scheduler.want(gen.world, gen.dimension, {self(), state.key}, state.epoch, wanted) do
        {:ok, pid} ->
          scheduler =
            case gen.scheduler do
              {^pid, _} = known -> known
              _ -> {pid, Process.monitor(pid)}
            end

          %{state | generation: %{gen | scheduler: scheduler, sent: wanted, failures: 0}}

        {:error, reason} ->
          failed(state, reason)
      end
    end
  end

  defp failed(state, reason) do
    gen = state.generation
    failures = gen.failures + 1

    if failures in [1, 10, 100],
      do: Logger.warning("Generating in region #{inspect(state.key)}: #{inspect(reason)}")

    delay = min(5000, 50 * failures)
    timer = Process.send_after(self(), {:resource, state.epoch, :generation_retry}, delay)
    %{state | generation: %{gen | failures: failures, retry: timer}}
  end

  @doc "The retry timer fired: tell the scheduler again."
  def retry(state), do: pump(%{state | generation: %{state.generation | retry: nil}})

  @doc "The scheduler went down: `{:ok, state}` (wanting everything again) if it was it."
  def down(%{generation: %{scheduler: {_, monitor}}} = state, monitor) do
    gen = %{state.generation | scheduler: nil, sent: %{}}
    {:ok, pump(%{state | generation: gen})}
  end

  def down(_state, _monitor), do: :error

  @doc "Whether chunks are wanted or calls wait for them."
  def busy?(%__MODULE__{} = gen), do: gen.sent != %{} or gen.deferred_count > 0

  @doc "These generated chunks are durable: the scheduler drops their proto state."
  def handed_over(state, chunks) do
    gen = state.generation
    Scheduler.handed_over(gen.world, gen.dimension, chunks)
    state
  end

  ## Results

  @doc "A full chunk from the scheduler."
  def received(state, full) do
    gen = state.generation
    chunk = {full.x, full.z}
    state = %{state | generation: %{gen | sent: Map.delete(gen.sent, chunk)}}

    if absent?(gen, chunk) do
      case FullChunk.parts([full], %{}, []) do
        {:ok, parts} -> install(state, parts)
        {:error, reason} -> generation_failed(state, [chunk], {:unusable_full_chunk, reason})
      end
    else
      state
    end
  end

  @doc "The scheduler could not generate `chunks`: they stay absent and their calls fail."
  def generation_failed(state, chunks, reason) do
    gen = state.generation
    chunks = Enum.filter(chunks, &absent?(gen, &1))

    Logger.error(
      "Region #{inspect(state.key)} cannot generate #{inspect(chunks)}: #{inspect(reason)}"
    )

    {calls, waiting} = Map.split(gen.deferred, chunks)

    for {_, list} <- calls,
        {_, from} <- list,
        do: GenServer.reply(from, Valimc.Error.reject(:chunk_generation_failed))

    count = gen.deferred_count - Enum.sum(Enum.map(calls, fn {_, list} -> length(list) end))

    gen = %{
      gen
      | failed: Enum.into(chunks, gen.failed),
        urgent: MapSet.difference(gen.urgent, MapSet.new(chunks)),
        sent: Map.drop(gen.sent, chunks),
        deferred: waiting,
        deferred_count: count
    }

    %{state | generation: gen}
  end

  # Install generated chunks; they were absent, so no reader saw them.
  defp install(state, parts) do
    gen = state.generation
    columns = Map.filter(parts.columns, fn {chunk, _} -> absent?(gen, chunk) end)
    chunks = Map.keys(columns)

    {:ok, changes} =
      case Blocks.put_columns(state.blocks, columns) do
        {:ok, _} = ok -> ok
        {:error, reason} -> exit({:generated_install_failed, reason})
      end

    entities =
      case BlockEntities.add(state.block_entities, parts.block_entities) do
        {:ok, entities} -> entities
        {:error, reason} -> exit({:generated_install_failed, reason})
      end

    ticks =
      Enum.reduce(parts.ticks, state.scheduled_ticks, fn {position, block, delay, priority},
                                                         acc ->
        case ScheduledTicks.schedule(acc, position, block, state.game_tick + delay, priority) do
          {:ok, next} -> next
          {:error, _} -> acc
        end
      end)

    installed = MapSet.new(chunks)
    {deferred, waiting} = Map.split(gen.deferred, chunks)
    count = gen.deferred_count - Enum.sum(Enum.map(deferred, fn {_, calls} -> length(calls) end))

    gen = %{
      gen
      | absent: MapSet.difference(gen.absent, installed),
        urgent: MapSet.difference(gen.urgent, installed),
        deferred: waiting,
        deferred_count: count
    }

    storage =
      state.storage
      |> RegionStorage.columns(columns)
      |> RegionStorage.post_processing(Map.take(parts.post_processing, chunks))

    state = %{
      state
      | generation: gen,
        block_entities: entities,
        scheduled_ticks: ticks,
        storage: storage
    }

    :ok =
      BlockSnapshot.publish_chunks(state.publication, state.blocks, chunks, state.revision)

    Valimc.Metrics.add(:worldgen_chunks, length(chunks))

    # Served chunks next to the new ones were lit with them unknown.
    state = RegionData.light_changed(state, Blocks.changed_chunks(changes))

    served =
      for {chunk, _, _} = change <- changes,
          MapSet.member?(state.served, chunk) and chunk not in chunks,
          do: change

    if served != [],
      do:
        World.publish(
          state.key,
          {:block_batch, Valimc.World.LightHalo.frames(state, served, :all)}
        )

    state = Valimc.World.LightHalo.columns_changed(state, columns)
    state = RegionData.wait_durable(state, [{:effect, {:generation_handed_over, chunks}}])

    deferred
    |> Enum.flat_map(fn {_, calls} -> Enum.reverse(calls) end)
    |> Enum.reduce(state, fn {message, from}, acc ->
      case RegionData.handle_call(message, from, acc) do
        {:reply, reply, acc} ->
          GenServer.reply(from, reply)
          acc

        {:noreply, acc} ->
          acc
      end
    end)
  end
end
