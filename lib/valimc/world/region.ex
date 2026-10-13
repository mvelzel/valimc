defmodule Valimc.World.Region do
  use GenServer

  @moduledoc "One state owner per region. Bounded supervised encoders share results across players."
  alias Valimc.World.{Chunk, Items, Store}
  alias Valimc.Protocol.Packets

  def start_link(key),
    do:
      GenServer.start_link(__MODULE__, key, name: {:via, Registry, {Valimc.RegionRegistry, key}})

  def child_spec(key),
    do: %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [key]},
      restart: :temporary,
      shutdown: 20_000
    }

  def flush(pid), do: GenServer.call(pid, :flush, 15_000)

  # Scene-only API: these operations must never consume a player inventory.
  def create_item({pid, epoch}, stack, position),
    do: GenServer.call(pid, {:create_item, epoch, stack, position}, 6000)

  def replace_item({pid, epoch, id, revision}, stack),
    do: GenServer.call(pid, {:replace_item, epoch, id, revision, stack}, 6000)

  def remove_item({pid, epoch, id, revision}),
    do: GenServer.call(pid, {:remove_item, epoch, id, revision}, 6000)

  def find_item({pid, epoch}, uuid), do: GenServer.call(pid, {:find_item, epoch, uuid})

  @impl true
  def init(key) do
    Process.flag(:trap_exit, true)
    {:ok, store} = Store.start_link(key)
    edits = Store.load(store)

    items =
      case Store.load_items(store) do
        {:ok, records} ->
          case Items.restore(key, records) do
            {:ok, items} -> items
            {:error, reason} -> exit({:item_load_failed, reason})
          end

        {:error, reason} ->
          exit({:item_load_failed, reason})
      end

    publication = :ets.new(:region_items, [:set, :protected, read_concurrency: true])
    :ets.insert(publication, {:items, items.views})

    Registry.update_value(Valimc.RegionRegistry, key, fn _ ->
      %{items: publication, epoch: items.epoch}
    end)

    by_chunk =
      Enum.reduce(edits, %{}, fn {{x, _, z} = pos, block}, acc ->
        chunk = Valimc.World.chunk_key(x, z)
        Map.update(acc, chunk, %{pos => block}, &Map.put(&1, pos, block))
      end)

    now = System.monotonic_time(:millisecond)
    Process.send_after(self(), :tick, 50)
    Process.send_after(self(), :save, 30_000)

    {:ok,
     %{
       key: key,
       items: items,
       item_publication: publication,
       item_pending: nil,
       store: store,
       edits: edits,
       by_chunk: by_chunk,
       cache: %{},
       jobs: %{},
       versions: %{},
       revision: 0,
       dirty: false,
       saving: false,
       next_tick: now + 50
     }}
  end

  @impl true
  def handle_call({:create_item, epoch, stack, position}, from, state) do
    item_request(epoch, from, state, fn ->
      Items.create(state.items, state.key, stack, position)
    end)
  end

  def handle_call({:replace_item, epoch, id, revision, stack}, from, state),
    do:
      item_request(epoch, from, state, fn ->
        Items.replace(state.items, epoch, id, revision, stack)
      end)

  def handle_call({:remove_item, epoch, id, revision}, from, state),
    do: item_request(epoch, from, state, fn -> Items.remove(state.items, epoch, id, revision) end)

  def handle_call({:find_item, epoch, uuid}, _from, state) do
    result =
      if epoch == state.items.epoch,
        do: Items.find(state.items, uuid),
        else: {:error, :stale_region}

    reply =
      case result do
        {:ok, {epoch, id, revision}} -> {:ok, {self(), epoch, id, revision}}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:chunk, key}, from, state) do
    cond do
      Valimc.World.region_key(key) != state.key ->
        {:reply, {:error, :wrong_region}, state}

      Map.has_key?(state.cache, key) ->
        Valimc.Metrics.add(:chunk_cache_hits)
        {:reply, state.cache[key], state}

      Map.has_key?(state.jobs, key) ->
        Valimc.Metrics.add(:chunk_requests_coalesced)
        jobs = Map.update!(state.jobs, key, &%{&1 | waiters: [from | &1.waiters]})
        {:noreply, %{state | jobs: jobs}}

      true ->
        jobs = Map.put(state.jobs, key, %{waiters: [from], pid: nil, monitor: nil, token: nil})
        {:noreply, start_job(%{state | jobs: jobs}, key)}
    end
  end

  def handle_call({:get_block, position}, _from, state),
    do: {:reply, Chunk.block_at(state.edits, position), state}

  def handle_call({:set_block, {x, y, z} = position, block}, _from, state) do
    key = Valimc.World.chunk_key(x, z)

    if Valimc.World.region_key(key) == state.key and Chunk.valid_y?(y) and block >= 0 and
         block < 65536 and
         (map_size(state.edits) < 131_072 or Map.has_key?(state.edits, position)) do
      edits = put_edit(state.edits, position, block)
      local = put_edit(Map.get(state.by_chunk, key, %{}), position, block)
      Valimc.World.publish(state.key, {:block, position, block})
      Valimc.Metrics.add(:block_edits)

      {:reply, :ok,
       %{
         state
         | edits: edits,
           by_chunk: Map.put(state.by_chunk, key, local),
           dirty: true,
           revision: state.revision + 1,
           cache: Map.delete(state.cache, key),
           versions: Map.update(state.versions, key, 1, &(&1 + 1))
       }}
    else
      {:reply, {:error, :invalid_block}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    result = Store.flush(state.store, state.edits)
    {:reply, result, %{state | dirty: result != :ok}}
  end

  defp item_request(epoch, from, state, work) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> item_result(work.(), from, state)
    end
  end

  defp item_result({:ok, items, {epoch, id, revision}}, from, state) do
    reply = {:ok, {self(), epoch, id, revision}}

    if items == state.items,
      do: {:reply, reply, state},
      else: commit_items(items, reply, from, state)
  end

  defp item_result({:ok, items}, from, state), do: commit_items(items, :ok, from, state)
  defp item_result({:error, _} = error, _from, state), do: {:reply, error, state}

  defp commit_items(items, reply, from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:item_commit_deadline, token}, 5000)
    Store.commit_items(state.store, items, self(), token)
    pending = %{token: token, timer: timer, items: items, reply: reply, from: from}
    {:noreply, %{state | item_pending: pending}}
  end

  defp put_edit(edits, {_, y, _} = pos, block) do
    if block == Chunk.base(y), do: Map.delete(edits, pos), else: Map.put(edits, pos, block)
  end

  defp start_job(state, key) do
    job = state.jobs[key]

    if job.pid do
      state
    else
      owner = self()
      token = make_ref()
      edits = Map.get(state.by_chunk, key, %{})
      version = Map.get(state.versions, key, 0)
      threshold = Valimc.config(:compression_threshold)

      case Task.Supervisor.start_child(Valimc.ChunkWorkers, fn ->
             started = System.monotonic_time(:microsecond)
             frame = Chunk.encode(key, edits) |> Packets.frame(threshold)
             Valimc.Metrics.add(:chunks_encoded)

             Valimc.Metrics.add(
               :chunk_encode_microseconds,
               System.monotonic_time(:microsecond) - started
             )

             send(owner, {:encoded, key, token, version, frame})
           end) do
        {:ok, pid} ->
          job = %{job | pid: pid, monitor: Process.monitor(pid), token: token}
          %{state | jobs: Map.put(state.jobs, key, job)}

        {:error, :max_children} ->
          Process.send_after(self(), {:retry_encode, key}, 10)
          state

        {:error, reason} ->
          for from <- job.waiters, do: GenServer.reply(from, {:error, reason})
          %{state | jobs: Map.delete(state.jobs, key)}
      end
    end
  end

  @impl true
  def handle_info(
        {:items_saved, writer, token, :ok},
        %{store: writer, item_pending: %{token: token} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    :ets.insert(state.item_publication, {:items, pending.items.views})
    GenServer.reply(pending.from, pending.reply)
    {:noreply, %{state | items: pending.items, item_pending: nil}}
  end

  def handle_info(
        {:items_saved, writer, token, {:error, reason}},
        %{store: writer, item_pending: %{token: token} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    GenServer.reply(pending.from, {:error, :item_commit_uncertain})
    require Logger
    Logger.error("Region item commit failed: #{inspect(reason)}")
    {:stop, {:item_storage_failed, reason}, %{state | item_pending: nil}}
  end

  def handle_info({:items_saved, _, _, _}, state), do: {:noreply, state}

  def handle_info({:item_commit_deadline, token}, %{item_pending: %{token: token}} = state),
    do: {:stop, :item_storage_timeout, state}

  def handle_info({:item_commit_deadline, _}, state), do: {:noreply, state}

  def handle_info({:encoded, key, token, version, frame}, state) do
    case state.jobs[key] do
      %{token: ^token} = job ->
        Process.demonitor(job.monitor, [:flush])

        if version == Map.get(state.versions, key, 0) do
          for from <- job.waiters, do: GenServer.reply(from, frame)

          {:noreply,
           %{state | jobs: Map.delete(state.jobs, key), cache: Map.put(state.cache, key, frame)}}
        else
          Valimc.Metrics.add(:stale_chunk_results_discarded)
          job = %{job | pid: nil, monitor: nil, token: nil}
          {:noreply, start_job(%{state | jobs: Map.put(state.jobs, key, job)}, key)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_encode, key}, state) do
    if Map.has_key?(state.jobs, key),
      do: {:noreply, start_job(state, key)},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.jobs, fn {_, job} -> job.monitor == ref end) do
      {key, job} ->
        for from <- job.waiters, do: GenServer.reply(from, {:error, {:encoder_failed, reason}})
        {:noreply, %{state | jobs: Map.delete(state.jobs, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    Valimc.Metrics.add(:region_ticks)
    Valimc.Metrics.add(:region_late_milliseconds, max(now - state.next_tick, 0))
    deadline = max(state.next_tick + 50, now + 1)
    Process.send_after(self(), :tick, deadline - now)
    {:noreply, %{state | next_tick: deadline}}
  end

  def handle_info(:save, state) do
    saving = state.dirty and not state.saving
    if saving, do: Store.snapshot(state.store, state.edits, self(), state.revision)
    Process.send_after(self(), :save, 30_000)
    {:noreply, %{state | saving: state.saving or saving}}
  end

  def handle_info({:saved, revision, result}, state) do
    {:noreply, %{state | saving: false, dirty: result != :ok or revision != state.revision}}
  end

  def handle_info({:EXIT, pid, reason}, %{store: pid} = state),
    do: {:stop, {:store_failed, reason}, state}

  @impl true
  def terminate(reason, state) do
    if state.item_pending do
      Process.cancel_timer(state.item_pending.timer)
      GenServer.reply(state.item_pending.from, {:error, :item_commit_uncertain})
    end

    for {_, job} <- state.jobs,
        job.pid != nil and Process.whereis(Valimc.ChunkWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.ChunkWorkers, job.pid)

    if reason in [:normal, :shutdown] and state.dirty, do: Store.flush(state.store, state.edits)

    if Process.alive?(state.store) do
      try do
        GenServer.stop(state.store, :normal, 1000)
      catch
        :exit, _ -> Process.exit(state.store, :kill)
      end
    end
  end
end
