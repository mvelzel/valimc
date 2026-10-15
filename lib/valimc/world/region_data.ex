defmodule Valimc.World.RegionData do
  @moduledoc "One storage resource's data and operations, executed by its owning process."
  alias Valimc.World.{BlockBatch, Chunk, Items, ItemTransfers, Store}
  alias Valimc.Protocol.Packets

  defstruct [
    :key,
    :items,
    :item_receipts,
    :item_storage_enabled,
    :item_publication,
    :item_pending,
    :store,
    :store_lease,
    :store_monitor,
    :edits,
    :by_chunk,
    :cache,
    :jobs,
    :versions,
    :revision,
    :dirty,
    :saving,
    :save_timer
  ]

  def load(key) do
    {:ok, store, store_lease} = Store.open(key)
    store_monitor = Process.monitor(store)
    edits = Store.load(store)

    {items, receipts, persistent} =
      case Store.load_items(store) do
        {:ok, %{records: records, receipts: receipts, persistent: persistent}} ->
          case Items.restore(key, records) do
            {:ok, items} -> {items, receipts, persistent}
            {:error, reason} -> exit({:item_load_failed, reason})
          end

        {:error, reason} ->
          exit({:item_load_failed, reason})
      end

    publication = :ets.new(:region_items, [:set, :protected, read_concurrency: true])
    :ets.insert(publication, {:items, items.views})

    by_chunk =
      Enum.reduce(edits, %{}, fn {{x, _, z} = pos, block}, acc ->
        chunk = Valimc.World.chunk_key(x, z)
        Map.update(acc, chunk, %{pos => block}, &Map.put(&1, pos, block))
      end)

    save_timer = Process.send_after(self(), {:resource, items.epoch, :save}, 30_000)

    %__MODULE__{
      key: key,
      items: items,
      item_receipts: receipts,
      item_storage_enabled: persistent,
      item_publication: publication,
      item_pending: nil,
      store: store,
      store_lease: store_lease,
      store_monitor: store_monitor,
      edits: edits,
      by_chunk: by_chunk,
      cache: %{},
      jobs: %{},
      versions: %{},
      revision: 0,
      dirty: false,
      saving: false,
      save_timer: save_timer
    }
  end

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

  def handle_call({:item_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      true ->
        plan_transfer(transfer, from, state)
    end
  end

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

  def handle_call({:item_transfer_receipt, epoch, source}, _from, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not (is_binary(source) and byte_size(source) == 16) -> {:error, :invalid_transfer_source}
        state.item_receipts[source] == nil -> {:error, :missing_transfer_receipt}
        true -> {:ok, {state.key, state.item_receipts[source]}}
      end

    {:reply, result, state}
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

  def handle_call({:observe_blocks, epoch, positions, expected_revision}, _from, state) do
    result =
      cond do
        not valid_block_query?(positions, expected_revision) ->
          {:error, :invalid_block_query}

        epoch != state.items.epoch ->
          {:error, :stale_owner}

        expected_revision != :any and expected_revision != state.revision ->
          {:error, :stale_revision}

        Enum.any?(positions, fn {x, _, z} ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != state.key
        end) ->
          {:error, :wrong_region}

        true ->
          {:ok,
           %{
             owner: {self(), state.items.epoch},
             region: state.key,
             revision: state.revision,
             blocks: Map.new(positions, &{&1, Chunk.block_at(state.edits, &1)})
           }}
      end

    {:reply, result, state}
  end

  def handle_call({:set_blocks, epoch, revision, %BlockBatch{} = batch}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      true ->
        edits =
          Enum.reduce(batch.edits, state.edits, fn {pos, block}, acc ->
            put_edit(acc, pos, block)
          end)

        if map_size(edits) > 131_072 do
          {:reply, {:error, :region_edit_limit}, state}
        else
          by_chunk =
            Enum.reduce(batch.edits, state.by_chunk, fn {{x, _, z} = pos, block}, acc ->
              key = Valimc.World.chunk_key(x, z)
              Map.put(acc, key, put_edit(Map.get(acc, key, %{}), pos, block))
            end)

          versions =
            Enum.reduce(batch.chunks, state.versions, &Map.update(&2, &1, 1, fn n -> n + 1 end))

          Valimc.World.publish(state.key, {:block_batch, batch.frames})
          Valimc.Metrics.add(:block_edits, map_size(batch.edits))

          next = %{
            state
            | edits: edits,
              by_chunk: by_chunk,
              versions: versions,
              cache: Map.drop(state.cache, batch.chunks),
              dirty: true,
              revision: state.revision + 1
          }

          {:reply, {:ok, next.revision}, next}
        end
    end
  end

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
    result = Store.flush(state.store, state.store_lease, state.edits)
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

  defp commit_items(items, reply, from, state),
    do: commit_items(items, reply, from, state, state.item_receipts)

  defp commit_items(items, reply, from, state, receipts) do
    token = make_ref()
    timer = send_after(state, {:item_commit_deadline, token}, 5000)

    Store.commit_items(
      state.store,
      state.store_lease,
      items,
      receipts,
      {self(), state.items.epoch},
      token
    )

    pending = %{
      phase: :writing,
      token: token,
      timer: timer,
      items: items,
      receipts: receipts,
      reply: reply,
      from: from
    }

    {:noreply, %{state | item_pending: pending}}
  end

  defp plan_transfer(transfer, from, state) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    items = state.items
    receipts = state.item_receipts
    key = state.key

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result = ItemTransfers.plan(items, receipts, key, transfer)
           send(owner, {:resource, epoch, {:item_transfer_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        pending = %{
          phase: :planning,
          token: token,
          from: from,
          worker: worker,
          monitor: Process.monitor(worker),
          timer: send_after(state, {:item_commit_deadline, token}, 5000)
        }

        {:noreply, %{state | item_pending: pending}}

      {:error, :max_children} ->
        {:reply, {:error, :item_workers_busy}, state}

      {:error, reason} ->
        {:reply, {:error, {:item_worker_failed, reason}}, state}
    end
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
      epoch = state.items.epoch
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

             send(owner, {:resource, epoch, {:encoded, key, token, version, frame}})
           end) do
        {:ok, pid} ->
          job = %{job | pid: pid, monitor: Process.monitor(pid), token: token}
          %{state | jobs: Map.put(state.jobs, key, job)}

        {:error, :max_children} ->
          send_after(state, {:retry_encode, key}, 10)
          state

        {:error, reason} ->
          for from <- job.waiters, do: GenServer.reply(from, {:error, reason})
          %{state | jobs: Map.delete(state.jobs, key)}
      end
    end
  end

  def handle_info(
        {:item_transfer_plan, worker, token, result},
        %{item_pending: %{phase: :planning, worker: worker, token: token} = pending} = state
      ) do
    Process.demonitor(pending.monitor, [:flush])

    case result do
      {:ok, items, receipts, :applied} ->
        Store.commit_items(
          state.store,
          state.store_lease,
          items,
          receipts,
          {self(), state.items.epoch},
          token
        )

        writing =
          pending
          |> Map.drop([:worker, :monitor])
          |> Map.merge(%{
            phase: :writing,
            items: items,
            receipts: receipts,
            reply: {:ok, :applied}
          })

        {:noreply, %{state | item_pending: writing}}

      {:ok, _, _, :already_applied} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:ok, :already_applied})
        {:noreply, %{state | item_pending: nil}}

      {:error, _} = error ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, error)
        {:noreply, %{state | item_pending: nil}}
    end
  end

  def handle_info({:item_transfer_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:items_saved, writer, token, :ok},
        %{store: writer, item_pending: %{phase: :writing, token: token} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    :ets.insert(state.item_publication, {:items, pending.items.views})
    GenServer.reply(pending.from, pending.reply)

    {:noreply,
     %{state | items: pending.items, item_receipts: pending.receipts, item_pending: nil}}
  end

  def handle_info(
        {:items_saved, writer, token, {:error, reason}},
        %{store: writer, item_pending: %{phase: :writing, token: token} = pending} = state
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

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{item_pending: %{phase: :planning, monitor: ref, worker: worker} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    GenServer.reply(pending.from, {:error, :item_plan_failed})
    {:noreply, %{state | item_pending: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, writer, reason},
        %{store: writer, store_monitor: ref} = state
      ),
      do: {:stop, {:store_failed, reason}, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.jobs, fn {_, job} -> job.monitor == ref end) do
      {key, job} ->
        for from <- job.waiters, do: GenServer.reply(from, {:error, {:encoder_failed, reason}})
        {:noreply, %{state | jobs: Map.delete(state.jobs, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:save, state) do
    saving = state.dirty and not state.saving

    if saving,
      do:
        Store.snapshot(
          state.store,
          state.store_lease,
          state.edits,
          {self(), state.items.epoch},
          state.revision
        )

    Process.cancel_timer(state.save_timer)
    timer = send_after(state, :save, 30_000)
    {:noreply, %{state | saving: state.saving or saving, save_timer: timer}}
  end

  def handle_info({:saved, writer, revision, result}, %{store: writer} = state) do
    {:noreply, %{state | saving: false, dirty: result != :ok or revision != state.revision}}
  end

  def handle_info({:saved, _, _, _}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  def valid_block_query?(positions, revision),
    do:
      (revision == :any or (is_integer(revision) and revision >= 0)) and
        valid_block_positions?(positions, 0)

  defp valid_block_positions?([], _), do: true

  defp valid_block_positions?([{x, y, z} | rest], count)
       when count < 128 and is_integer(x) and is_integer(y) and is_integer(z) do
    abs(x) < 30_000_000 and abs(z) < 30_000_000 and abs(y) <= 1_000_000 and
      valid_block_positions?(rest, count + 1)
  end

  defp valid_block_positions?(_, _), do: false

  defp send_after(state, message, delay),
    do: Process.send_after(self(), {:resource, state.items.epoch, message}, delay)

  def terminate(reason, state) do
    Process.cancel_timer(state.save_timer)

    if state.item_pending do
      Process.cancel_timer(state.item_pending.timer)
      GenServer.reply(state.item_pending.from, {:error, :item_commit_uncertain})

      if state.item_pending.phase == :planning and Process.whereis(Valimc.ItemWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.ItemWorkers, state.item_pending.worker)
    end

    for {_, job} <- state.jobs,
        job.pid != nil and Process.whereis(Valimc.ChunkWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.ChunkWorkers, job.pid)

    if reason in [:normal, :shutdown] and state.dirty,
      do: Store.flush(state.store, state.store_lease, state.edits)

    Process.demonitor(state.store_monitor, [:flush])

    if Process.alive?(state.store) do
      try do
        Store.close(state.store, state.store_lease)
      catch
        :exit, _ -> Process.exit(state.store, :kill)
      end
    end
  end
end
