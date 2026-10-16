defmodule Valimc.World.RegionData do
  @moduledoc "One storage resource's data and operations, executed by its owning process."
  alias Valimc.World.{
    BlockBatch,
    Chunk,
    Items,
    ItemTransfers,
    MiningPermits,
    MiningTransfers,
    PlacementPermits,
    PlacementTransfers,
    Store
  }

  alias Valimc.Protocol.Packets

  defstruct [
    :key,
    :items,
    :item_receipts,
    :item_storage_enabled,
    :item_publication,
    :item_pending,
    :mining_permits,
    :placement_permits,
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
      mining_permits: %MiningPermits{},
      placement_permits: %PlacementPermits{},
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

  def handle_call({:advance_items, epoch, steps, deadline}, from, state) do
    item_request(epoch, from, state, fn ->
      if is_integer(deadline) and System.monotonic_time(:millisecond) < deadline,
        do: Items.advance(state.items, state.key, epoch, steps),
        else: {:error, :expired_item_step}
    end)
  end

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

  def handle_call({:reserve_mining, epoch, positions}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not valid_block_query?(positions, :any) or positions == [] ->
        {:reply, {:error, :invalid_mining_reservation}, state}

      not Enum.all?(positions, fn {x, y, z} ->
        Chunk.valid_y?(y) and Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key
      end) ->
        {:reply, {:error, :wrong_region}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        blocks = Map.new(positions, &{&1, Chunk.block_at(state.edits, &1)})

        case MiningPermits.reserve(
               state.mining_permits,
               blocks,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, token} ->
            {:reply, {:ok, %{permit: token, expected: blocks}},
             %{state | mining_permits: permits}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:renew_mining, epoch, permit}, _from, state) do
    if epoch == state.items.epoch do
      case MiningPermits.renew(state.mining_permits, permit, System.monotonic_time(:millisecond)) do
        {:ok, permits, blocks} ->
          {:reply, {:ok, blocks}, %{state | mining_permits: permits}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :stale_owner}, state}
    end
  end

  def handle_call({:release_mining, epoch, permit}, _from, state) do
    if epoch == state.items.epoch,
      do:
        {:reply, :ok,
         %{state | mining_permits: MiningPermits.remove(state.mining_permits, permit)}},
      else: {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:mining_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> plan_block_transfer(:mining, transfer, from, state)
    end
  end

  def handle_call({:reserve_placement, epoch, revision, expected}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not is_map(expected) or map_size(expected) not in 1..2 ->
        {:reply, {:error, :invalid_placement_reservation}, state}

      not valid_block_query?(Map.keys(expected), revision) ->
        {:reply, {:error, :invalid_placement_reservation}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      not Enum.all?(expected, fn {{x, y, z}, block} ->
        Chunk.valid_y?(y) and Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key and
            Chunk.block_at(state.edits, {x, y, z}) == block
      end) ->
        {:reply, {:error, :placement_context_changed}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        case PlacementPermits.reserve(
               state.placement_permits,
               expected,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, token} ->
            {:reply, {:ok, %{permit: token, expected: expected}},
             %{state | placement_permits: permits}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:release_placement, epoch, permit}, _from, state) do
    if epoch == state.items.epoch,
      do:
        {:reply, :ok,
         %{state | placement_permits: PlacementPermits.remove(state.placement_permits, permit)}},
      else: {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:placement_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> plan_block_transfer(:placement, transfer, from, state)
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

  def handle_call({:remove_block, position}, from, state) do
    replacement =
      state.edits |> Chunk.block_at(position) |> Valimc.Physics.FluidBlocks.after_removal()

    handle_call({:set_block, position, replacement}, from, state)
  end

  def handle_call({:correct_blocks, epoch, positions, connection}, from, state) do
    if is_pid(connection) and valid_block_query?(positions, :any) and length(positions) <= 2 do
      case handle_call({:observe_blocks, epoch, positions, :any}, from, state) do
        {:reply, {:ok, observed}, state} ->
          for {position, block} <- observed.blocks,
              do: Valimc.Connection.deliver(connection, {:block, position, block})

          {:reply, :ok, state}

        error ->
          error
      end
    else
      {:reply, {:error, :invalid_block_query}, state}
    end
  end

  def handle_call({:set_blocks, epoch, revision, %BlockBatch{} = batch}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        case block_proposal(state, batch) do
          {:ok, proposal} ->
            next = publish_blocks(state, batch, proposal, true)
            {:reply, {:ok, next.revision}, next}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:place_block, epoch, revision, %BlockBatch{} = batch, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    if is_integer(deadline) and deadline > now and deadline <= now + 250 and
         map_size(batch.edits) == 1 do
      handle_call({:set_blocks, epoch, revision, batch}, from, state)
    else
      {:reply, {:error, :invalid_or_expired_placement}, state}
    end
  end

  def handle_call({:set_block, {x, y, z} = position, block}, _from, state) do
    key = Valimc.World.chunk_key(x, z)

    if block_transfer_writing?(state) do
      {:reply, {:error, :mining_storage_busy}, state}
    else
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
             mining_permits: MiningPermits.invalidate(state.mining_permits, %{position => block}),
             placement_permits:
               PlacementPermits.invalidate(state.placement_permits, %{position => block}),
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
  end

  def handle_call(:flush, _from, %{item_pending: %{kind: kind, phase: :writing}} = state)
      when kind in [:mining, :placement],
      do: {:reply, {:error, :mining_storage_busy}, state}

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

  defp item_result({:ok, items, handles}, from, state) when is_list(handles) do
    handles = Enum.map(handles, fn {epoch, id, revision} -> {self(), epoch, id, revision} end)

    if items == state.items,
      do: {:reply, {:ok, handles}, state},
      else: commit_items(items, {:ok, handles}, from, state)
  end

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
          kind: :item_transfer,
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

  defp block_transfer_writing?(state),
    do:
      match?(
        %{kind: kind, phase: :writing} when kind in [:mining, :placement],
        state.item_pending
      )

  defp permit_matches?(state, kind, %{permit: token, expected: expected}) do
    {module, permits} = permit_store(state, kind)
    module.lookup(permits, token, System.monotonic_time(:millisecond)) == {:ok, expected}
  end

  defp permit_matches?(_, _, _), do: false
  defp permit_store(state, :mining), do: {MiningPermits, state.mining_permits}
  defp permit_store(state, :placement), do: {PlacementPermits, state.placement_permits}
  defp transfer_module(:mining), do: MiningTransfers
  defp transfer_module(:placement), do: PlacementTransfers

  defp plan_block_transfer(kind, transfer, from, state) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    items = state.items
    receipts = state.item_receipts
    key = state.key
    eligible = permit_matches?(state, kind, transfer)
    module = transfer_module(kind)

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result =
             with {:ok, plan} <- module.plan(items, receipts, key, transfer, eligible) do
               plan = Map.put(plan, :kind, kind)

               if plan.result == :applied do
                 changes =
                   if kind == :placement do
                     plan.edits
                   else
                     Map.new(plan.expected, fn {pos, block} ->
                       {pos, Valimc.Physics.FluidBlocks.after_removal(block)}
                     end)
                   end

                 with {:ok, batch} <- BlockBatch.prepare(changes),
                      do: {:ok, Map.put(plan, :batch, batch)}
               else
                 {:ok, plan}
               end
             end

           send(owner, {:resource, epoch, {:block_transfer_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        pending = %{
          kind: kind,
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

  defp block_proposal(state, batch) do
    edits =
      Enum.reduce(batch.edits, state.edits, fn {pos, block}, acc -> put_edit(acc, pos, block) end)

    if map_size(edits) > 131_072 do
      {:error, :region_edit_limit}
    else
      by_chunk =
        Enum.reduce(batch.edits, state.by_chunk, fn {{x, _, z} = pos, block}, acc ->
          key = Valimc.World.chunk_key(x, z)
          Map.put(acc, key, put_edit(Map.get(acc, key, %{}), pos, block))
        end)

      versions =
        Enum.reduce(batch.chunks, state.versions, &Map.update(&2, &1, 1, fn n -> n + 1 end))

      {:ok, %{edits: edits, by_chunk: by_chunk, versions: versions, revision: state.revision + 1}}
    end
  end

  defp publish_blocks(state, batch, proposal, dirty) do
    Valimc.World.publish(state.key, {:block_batch, batch.frames})
    Valimc.Metrics.add(:block_edits, map_size(batch.edits))

    state
    |> struct!(proposal)
    |> Map.merge(%{
      cache: Map.drop(state.cache, batch.chunks),
      dirty: dirty,
      mining_permits: MiningPermits.invalidate(state.mining_permits, batch.edits),
      placement_permits: PlacementPermits.invalidate(state.placement_permits, batch.edits)
    })
  end

  defp commit_block_transfer(plan, pending, state) do
    cond do
      plan.result in [:already_applied, :already_rejected] ->
        GenServer.reply(pending.from, {:ok, plan.result})
        {:noreply, %{state | item_pending: nil}}

      plan.result == :rejected ->
        commit_rejected_block_transfer(plan, pending.from, state)

      not permit_matches?(state, plan.kind, plan) ->
        commit_rejected_block_transfer(
          transfer_module(plan.kind).reject(plan, state.items, state.item_receipts),
          pending.from,
          state
        )

      true ->
        case block_proposal(state, plan.batch) do
          {:ok, proposal} ->
            token = make_ref()

            Store.commit_mining(
              state.store,
              state.store_lease,
              %{
                edits: proposal.edits,
                changes: plan.batch.edits,
                items: plan.items,
                receipts: plan.receipts
              },
              {self(), state.items.epoch},
              token
            )

            writing = %{
              kind: plan.kind,
              phase: :writing,
              token: token,
              timer: send_after(state, {:item_commit_deadline, token}, 5000),
              from: pending.from,
              batch: plan.batch,
              proposal: proposal,
              items: plan.items,
              receipts: plan.receipts
            }

            {:noreply, %{state | item_pending: writing}}

          {:error, _} ->
            commit_rejected_block_transfer(
              transfer_module(plan.kind).reject(plan, state.items, state.item_receipts),
              pending.from,
              state
            )
        end
    end
  end

  defp commit_rejected_block_transfer(plan, from, state) do
    {module, permits} = permit_store(state, plan.kind)
    field = if plan.kind == :mining, do: :mining_permits, else: :placement_permits
    state = Map.put(state, field, module.remove(permits, plan.permit))

    {:noreply, next} =
      commit_items(
        state.items,
        {:ok, :rejected},
        from,
        state,
        plan.receipts
      )

    {:noreply, %{next | item_pending: Map.put(next.item_pending, :kind, plan.kind)}}
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
        %{
          item_pending:
            %{kind: :item_transfer, phase: :planning, worker: worker, token: token} = pending
        } = state
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
        {:block_transfer_plan, worker, token, result},
        %{
          item_pending: %{kind: kind, phase: :planning, worker: worker, token: token} = pending
        } = state
      )
      when kind in [:mining, :placement] do
    Process.demonitor(pending.monitor, [:flush])
    Process.cancel_timer(pending.timer)

    case result do
      {:ok, %{kind: ^kind} = plan} ->
        commit_block_transfer(plan, pending, state)

      {:error, _} = error ->
        GenServer.reply(pending.from, error)
        {:noreply, %{state | item_pending: nil}}
    end
  end

  def handle_info({:block_transfer_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:mining_saved, writer, token, :ok},
        %{
          store: writer,
          item_pending: %{kind: kind, phase: :writing, token: token, batch: batch} = pending
        } = state
      )
      when kind in [:mining, :placement] do
    Process.cancel_timer(pending.timer)
    next = publish_blocks(state, batch, pending.proposal, false)
    :ets.insert(state.item_publication, {:items, pending.items.views})
    GenServer.reply(pending.from, {:ok, :applied})
    {:noreply, %{next | items: pending.items, item_receipts: pending.receipts, item_pending: nil}}
  end

  def handle_info(
        {:mining_saved, writer, token, {:error, reason}},
        %{
          store: writer,
          item_pending: %{kind: kind, phase: :writing, token: token, batch: _} = pending
        } = state
      )
      when kind in [:mining, :placement] do
    Process.cancel_timer(pending.timer)
    GenServer.reply(pending.from, {:error, :mining_commit_uncertain})
    {:stop, {:mining_storage_failed, reason}, %{state | item_pending: nil}}
  end

  def handle_info({:mining_saved, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:items_saved, writer, token, :ok},
        %{store: writer, item_pending: %{phase: :writing, token: token} = pending} = state
      )
      when not is_map_key(pending, :batch) do
    Process.cancel_timer(pending.timer)
    :ets.insert(state.item_publication, {:items, pending.items.views})
    GenServer.reply(pending.from, pending.reply)

    {:noreply,
     %{state | items: pending.items, item_receipts: pending.receipts, item_pending: nil}}
  end

  def handle_info(
        {:items_saved, writer, token, {:error, reason}},
        %{store: writer, item_pending: %{phase: :writing, token: token} = pending} = state
      )
      when not is_map_key(pending, :batch) do
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
    saving = state.dirty and not state.saving and not block_transfer_writing?(state)

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

  def handle_info({:table_request, epoch, connection, ref, position, grant}, state)
      when is_pid(connection) and is_reference(ref) do
    decision =
      cond do
        epoch != state.items.epoch ->
          {:error, :stale_owner}

        not valid_block_query?([position], :any) ->
          {:error, :invalid_block_query}

        Valimc.World.region_key(Valimc.World.chunk_key(elem(position, 0), elem(position, 2))) !=
            state.key ->
          {:error, :wrong_region}

        true ->
          Valimc.TableAccess.authorize(
            Chunk.block_at(state.edits, position),
            position,
            grant,
            System.monotonic_time(:millisecond)
          )
      end

    Valimc.Connection.deliver(
      connection,
      {:table_admitted, ref, {self(), state.items.epoch}, decision}
    )

    {:noreply, state}
  end

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

    if reason in [:normal, :shutdown] and state.dirty do
      # A queued atomic write must never be followed by the old pre-commit snapshot.
      edits =
        case state.item_pending do
          %{kind: kind, phase: :writing, proposal: proposal} when kind in [:mining, :placement] ->
            proposal.edits

          _ ->
            state.edits
        end

      Store.flush(state.store, state.store_lease, edits)
    end

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
