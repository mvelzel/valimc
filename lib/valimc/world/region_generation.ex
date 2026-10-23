defmodule Valimc.World.RegionGeneration do
  @moduledoc """
  Generation of a region's absent chunks (VMC-075), run by its owner.

  A region of a generated world loads without generating: the chunks its log
  has no column for are absent. Loading tickets (`Valimc.World.Tickets`) say
  which chunks are wanted; calls that need an absent chunk want it urgently
  (`urgent/2`). The owner tells its dimension's generation scheduler
  (`Valimc.Worldgen.Scheduler`, VMC-077n) which absent chunks it wants, and
  which of them urgently, whenever that changes, and reports the chunks it has
  when it loads. The order is the scheduler's, from the players (VMC-077x1). The scheduler sends chunks once they are full, lit alone
  where they were generated (VMC-077c), in deliveries (VMC-077w).

  A delivery's chunks are installed together when it arrives and their
  column images join the owner's next frame (`RegionStorage`, VMC-077f):
  their columns adopt their light and light crosses their faces, their block
  entities and ticks are added, their snapshots published, neighbours' rings
  and served chunks' light updated, and the calls that waited for them run
  again. The scheduler drops their proto state once that frame is durable. A chunk whose generation failed stays absent
  and its waiting calls fail.

  Until then an absent chunk is like a chunk of an unloaded neighbour region:
  the owner's block reads see nothing there and edits of it are refused.
  """
  alias Valimc.Data.Grid
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
    size = Grid.region_size()

    for cz <- (rz * size)..(rz * size + size - 1),
        cx <- (rx * size)..(rx * size + size - 1),
        do: {cx, cz}
  end

  @doc "The generation state of section `key` of `dimension` whose log holds column `images`."
  def new(dimension, key, images) do
    path = Valimc.config(:world_path, key)
    world = Spec.fetch(path)
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
        {:reply, Valimc.Data.Error.reject(:chunk_generation_failed), state}

      gen.deferred_count >= @max_deferred ->
        {:reply, Valimc.Data.Error.retry(:chunk_generating), state}

      true ->
        deferred = Map.update(gen.deferred, chunk, [{message, from}], &[{message, from} | &1])
        gen = %{gen | deferred: deferred, deferred_count: gen.deferred_count + 1}
        {:noreply, urgent(%{state | generation: gen}, [chunk])}
    end
  end

  ## Wants

  @doc "The absent chunks of loading `tickets` and urgent calls: `chunk => urgent?`."
  def wanted(%__MODULE__{} = gen, %Tickets{} = tickets) do
    wanted =
      for set <- Tickets.loading(tickets), chunk <- set, into: %{}, do: {chunk, false}

    gen.urgent
    |> Enum.into(wanted, &{&1, true})
    |> Map.filter(fn {chunk, _} ->
      absent?(gen, chunk) and not MapSet.member?(gen.failed, chunk)
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
      known = with {pid, _} <- gen.scheduler, do: pid

      case Scheduler.want(
             gen.world,
             gen.dimension,
             {self(), state.key},
             state.epoch,
             wanted,
             known
           ) do
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
    scheduler = with {pid, _} <- gen.scheduler, do: pid
    Scheduler.handed_over(gen.world, gen.dimension, chunks, scheduler)
    state
  end

  ## Results

  @doc """
  Full chunks from the scheduler, installed in one pass (VMC-077w); an
  unusable one fails alone.
  """
  def received(state, fulls) do
    gen = state.generation
    chunks = for full <- fulls, do: {full.x, full.z}
    state = %{state | generation: %{gen | sent: Map.drop(gen.sent, chunks)}}

    case Enum.filter(fulls, &absent?(gen, {&1.x, &1.z})) do
      [] ->
        state

      fulls ->
        case FullChunk.parts(fulls, %{}, []) do
          {:ok, parts} ->
            install(state, parts)

          {:error, reason} ->
            {usable, unusable} =
              Enum.split_with(fulls, &match?({:ok, _}, FullChunk.parts([&1], %{}, [])))

            # Usable alone but not together: none is.
            unusable = if unusable == [], do: fulls, else: unusable
            chunks = for full <- unusable, do: {full.x, full.z}
            state = generation_failed(state, chunks, {:unusable_full_chunk, reason})
            if usable == [] or unusable == fulls, do: state, else: received(state, usable)
        end
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
        do: GenServer.reply(from, Valimc.Data.Error.reject(:chunk_generation_failed))

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
      ScheduledTicks.schedule_all(
        state.scheduled_ticks,
        for(
          {position, block, delay, priority} <- parts.ticks,
          do: {position, block, state.game_tick + delay, priority}
        )
      )

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

    storage = RegionStorage.columns(state.storage, columns)

    state = %{
      state
      | generation: gen,
        block_entities: entities,
        scheduled_ticks: ticks,
        post: Map.merge(state.post, Map.take(parts.post_processing, chunks)),
        structures: Map.merge(state.structures, Map.take(parts.structures, chunks)),
        storage: storage
    }

    :ok =
      BlockSnapshot.publish_chunks(state.publication, state.blocks, chunks, state.revision)

    # The entities structures and features added (VMC-042b) and the
    # creatures a chunk gets as it generates (VMC-042a), durable with it.
    placed = Enum.flat_map(chunks, &Map.get(parts.entities, &1, []))

    creatures =
      if Valimc.World.Spawning.enabled?(state.key),
        do: Valimc.World.Spawning.generated(state, chunks),
        else: []

    state = RegionData.spawned(state, placed ++ creatures, [], [])

    Valimc.Data.Metrics.add(:worldgen_chunks, length(chunks))

    # Served chunks next to the new ones were lit with them unknown.
    state = RegionData.light_changed(state, Blocks.changed_chunks(changes))

    served =
      for {chunk, _, _} = change <- changes,
          MapSet.member?(state.served, chunk) and chunk not in chunks,
          do: change

    if served != [],
      do:
        World.publish(
          RegionData.route_key(state),
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
