defmodule Valimc.World.CookingOrbRuntime do
  @moduledoc "Bounded local/remote XP proposals; durable ACK before observation and receipt."
  alias Valimc.Protocol.EntityPackets

  alias Valimc.World.{
    CookingOrbs,
    CookingOrbTransfers,
    CookingOrbBodies,
    EntityView,
    RegionData
  }

  defstruct job: nil,
            seen: nil,
            retry_at: nil,
            cursor: nil,
            ledger: %{},
            views: %{},
            revision: 0,
            consumption_revision: 0,
            body_revision: 0,
            receipt: nil,
            delivery: nil,
            delivery_cursor: nil,
            delivery_seen: nil,
            delivery_retry_at: nil

  @max_view_bytes 1_048_576

  def tick(state, now) do
    runtime = state.cooking_orbs
    cs = state.containers

    cond do
      not state.item_storage_enabled or runtime.job != nil or RegionData.write_busy(state) != nil ->
        state

      is_integer(runtime.retry_at) and now < runtime.retry_at ->
        state

      runtime.receipt == nil and runtime.revision == cs.orb_transfers.revision and
        runtime.consumption_revision == cs.orb_consumption.revision and
        runtime.body_revision == cs.orb_bodies.revision and
        map_size(runtime.ledger) ==
          map_size(cs.cooking_orbs) + map_size(cs.orb_transfers.incoming) and
          (map_size(cs.pending_awards) ==
             map_size(cs.cooking_orbs) + map_size(cs.orb_transfers.outgoing) or
             (runtime.seen == stamp(cs) and runtime.retry_at == nil)) ->
        state

      true ->
        start(state, now, :scan, nil, nil)
    end
  end

  def adopt(state, epoch, bytes, deadline, from) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      not is_binary(bytes) or byte_size(bytes) > CookingOrbTransfers.max_request_bytes() ->
        {:reply, {:error, :invalid_cooking_orb_transfer}, state}

      not is_integer(deadline) or now() >= deadline ->
        {:reply, {:error, :expired_cooking_orb_transfer}, state}

      RegionData.write_busy(state) != nil or state.cooking_orbs.job != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      true ->
        next = start(state, now(), {:adopt, bytes}, from, deadline)

        if next.cooking_orbs.job,
          do: {:noreply, next},
          else: {:reply, {:error, :cooking_orb_workers_busy}, next}
    end
  end

  defp start(state, now, operation, from, deadline) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    containers = state.containers
    runtime = state.cooking_orbs
    key = state.key

    case Task.Supervisor.start_child(
           Valimc.ItemWorkers,
           Valimc.Dimension.bind(fn ->
             result =
               case operation do
                 :scan -> plan(containers, key, epoch, runtime)
                 {:adopt, bytes} -> plan_adoption(containers, key, epoch, runtime, bytes)
               end

             send(owner, {:resource, epoch, {:cooking_orb_plan, self(), token, result}})
           end)
         ) do
      {:ok, worker} ->
        job = %{
          worker: worker,
          token: token,
          monitor: Process.monitor(worker),
          timer: timer(state, {:cooking_orb_deadline, token}, 2000),
          ledger: containers.cooking_orbs,
          transfers: containers.orb_transfers,
          consumption: containers.orb_consumption,
          bodies: containers.orb_bodies,
          stamp: stamp(containers),
          from: from,
          deadline: deadline
        }

        %{state | cooking_orbs: %{runtime | job: job, retry_at: nil}}

      {:error, _} ->
        retry(state, now + 100)
    end
  end

  @doc false
  def plan(containers, key, epoch, runtime) do
    ledger = owned_ledger(containers)

    cond do
      runtime.ledger != ledger or runtime.revision != containers.orb_transfers.revision or
        runtime.consumption_revision != containers.orb_consumption.revision or
          runtime.body_revision != containers.orb_bodies.revision ->
        {:refresh, publication(containers, runtime.views, epoch)}

      runtime.receipt != nil ->
        {id, digest} = runtime.receipt

        with {:ok, proposed, status} <-
               CookingOrbTransfers.acknowledge(containers, key, id, digest) do
          if status == :already_delivered,
            do: {:settled, id},
            else:
              {:settle, id, digest, containers.pending_awards[id], proposed.orb_transfers,
               publication(proposed, runtime.views, epoch)}
        end

      true ->
        plan_award(containers, key, epoch, runtime)
    end
  rescue
    _ -> {:error, :orb_plan_failed}
  end

  defp plan_award(containers, key, epoch, runtime) do
    ids = containers.pending_awards |> Map.keys() |> Enum.sort() |> rotate(runtime.cursor)

    id =
      Enum.find(ids, fn id ->
        not Map.has_key?(containers.cooking_orbs, id) and
          not Map.has_key?(containers.orb_transfers.outgoing, id)
      end)

    if id do
      award = containers.pending_awards[id]

      if owned?(key, award.position) do
        case CookingOrbs.materialize(containers, key, id) do
          {:ok, proposed, :materialized} ->
            {:install, id, award, proposed.cooking_orbs[id],
             publication(proposed, runtime.views, epoch)}

          {:error, reason} ->
            {:refused, id, reason}
        end
      else
        case CookingOrbTransfers.prepare(containers, key, id) do
          {:ok, proposed, _, :prepared} ->
            {:route, id, award, proposed.orb_transfers,
             publication(proposed, runtime.views, epoch)}

          {:error, reason} ->
            {:refused, id, reason}
        end
      end
    else
      :idle
    end
  end

  defp plan_adoption(containers, key, epoch, runtime, bytes) do
    with {:ok, request} <- CookingOrbTransfers.decode_request(bytes),
         {:ok, proposed, status} <- CookingOrbTransfers.accept(containers, key, request) do
      if status == :already_applied,
        do: {:duplicate, request},
        else:
          {:adopt, request, proposed.orb_transfers, publication(proposed, runtime.views, epoch)}
    end
  rescue
    _ -> {:error, :orb_plan_failed}
  end

  def result(state, worker, token, result) do
    case state.cooking_orbs.job do
      %{worker: ^worker, token: ^token} = job ->
        clear_job(job)
        state = put_in(state.cooking_orbs.job, nil)

        if current?(state, job),
          do: accept(state, job, result),
          else: reject(state, job, :stale_cooking_orb_plan)

      _ ->
        {:noreply, state}
    end
  end

  defp current?(state, job),
    do:
      state.item_pending == nil and state.containers.cooking_orbs === job.ledger and
        state.containers.orb_transfers === job.transfers and
        state.containers.orb_consumption === job.consumption and
        state.containers.orb_bodies === job.bodies and
        (job.deadline == nil or now() < job.deadline)

  defp accept(state, _job, {:refresh, views}), do: {:noreply, publish(state, views)}

  defp accept(state, job, {:install, id, award, records, views}) do
    if state.containers.pending_awards[id] === award do
      commit(
        state,
        job,
        id,
        %{state.containers | cooking_orbs: Map.put(job.ledger, id, records)},
        views
      )
    else
      reject(state, job, :stale_cooking_award)
    end
  end

  defp accept(state, job, {:route, id, award, transfers, views}) do
    if state.containers.pending_awards[id] === award do
      commit(state, job, id, %{state.containers | orb_transfers: transfers}, views)
    else
      reject(state, job, :stale_cooking_award)
    end
  end

  defp accept(state, job, {:settle, id, digest, award, transfers, views}) do
    if state.cooking_orbs.receipt == {id, digest} and
         state.containers.pending_awards[id] === award do
      commit(state, job, id, %{state.containers | orb_transfers: transfers}, views, id)
    else
      reject(state, job, :stale_cooking_orb_receipt)
    end
  end

  defp accept(state, job, {:adopt, request, transfers, views}),
    do: commit(state, job, request.id, %{state.containers | orb_transfers: transfers}, views)

  defp accept(state, job, {:duplicate, _request}) do
    reply(job.from, {:ok, :already_applied})
    {:noreply, state}
  end

  defp accept(state, _job, {:settled, id}) do
    runtime = state.cooking_orbs

    receipt =
      case runtime.receipt do
        {^id, _} -> nil
        other -> other
      end

    {:noreply, %{state | cooking_orbs: %{runtime | receipt: receipt}}}
  end

  defp accept(state, job, :idle),
    do:
      {:noreply, %{state | cooking_orbs: %{state.cooking_orbs | seen: job.stamp, retry_at: nil}}}

  defp accept(state, _job, {:refused, id, _}),
    do: {:noreply, retry(put_in(state.cooking_orbs.cursor, id), now() + 1000)}

  defp accept(state, job, {:error, reason}), do: reject(state, job, reason)

  defp reject(state, job, reason) do
    reply(job.from, {:error, reason})
    {:noreply, retry(state, now() + 100)}
  end

  defp commit(state, job, id, containers, views),
    do: commit(state, job, id, containers, views, nil)

  defp commit(state, job, id, containers, views, settled) do
    # Adopted at once, so the snapshot must be storable before it replaces state.
    case Valimc.World.Containers.encode(state.key, containers) do
      {:ok, _} ->
        runtime = state.cooking_orbs
        receipt = if settled, do: nil, else: runtime.receipt

        state = %{
          state
          | containers: containers,
            cooking_orbs: %{runtime | cursor: id, seen: nil, retry_at: nil, receipt: receipt}
        }

        # The orbs leave for another owner: the reply and the views wait for
        # the frame that records it.
        {:noreply,
         RegionData.wait_durable(state, [
           {:effect, {:cooking_orbs, views}},
           {:reply, job.from, {:ok, :applied}}
         ])}

      {:error, _} ->
        reply(job.from, {:error, :cooking_orb_transfer_capacity})
        {:noreply, retry(put_in(state.cooking_orbs.cursor, id), now() + 1000)}
    end
  end

  @doc false
  def durable(state, views), do: publish(state, views)

  def expired(state, token) do
    case state.cooking_orbs.job do
      %{token: ^token} = job ->
        clear_job(job)
        Process.exit(job.worker, :kill)
        reply(job.from, {:error, :cooking_orb_plan_timeout})
        {:noreply, retry(put_in(state.cooking_orbs.job, nil), now() + 1000)}

      _ ->
        {:noreply, state}
    end
  end

  def down(state) do
    job = state.cooking_orbs.job
    clear_job(job)
    reply(job.from, {:error, :cooking_orb_plan_failed})
    {:noreply, retry(put_in(state.cooking_orbs.job, nil), now() + 100)}
  end

  def terminate(runtime) do
    if runtime.job do
      clear_job(runtime.job)
      reply(runtime.job.from, {:error, :cooking_orb_owner_stopped})
      Process.exit(runtime.job.worker, :kill)
    end
  end

  defp publish(state, %{
         ledger: ledger,
         views: views,
         revision: revision,
         consumption_revision: consumed,
         body_revision: body_revision
       }) do
    Valimc.World.EntityPublication.publish(
      state.item_publication,
      state.items.epoch,
      :orbs,
      views
    )

    %{
      state
      | cooking_orbs: %{
          state.cooking_orbs
          | ledger: ledger,
            views: views,
            revision: revision,
            consumption_revision: consumed,
            body_revision: body_revision
        }
    }
  end

  defp owned_ledger(containers), do: CookingOrbs.owned_records(containers)

  defp publication(containers, existing, epoch) do
    ledger = owned_ledger(containers)
    counts = containers.orb_consumption.counts

    active = CookingOrbBodies.project(containers)

    views =
      views(active, existing, epoch)
      |> Map.new(fn {id, v} -> {id, Map.put(v, :consumed, Map.get(counts, v.uuid, 0))} end)

    %{
      views: views,
      ledger: ledger,
      revision: containers.orb_transfers.revision,
      consumption_revision: containers.orb_consumption.revision,
      body_revision: containers.orb_bodies.revision
    }
  end

  defp views(ledger, existing, epoch) do
    by_uuid = Map.new(existing, fn {id, view} -> {view.uuid, {id, view}} end)
    records = for {_, orbs} <- ledger, {uuid, record} <- orbs, do: {uuid, record}
    true = length(records) <= CookingOrbs.max_records()

    {entries, bytes} =
      Enum.map_reduce(records, 0, fn {uuid, record}, size ->
        {id, view} = Map.get_lazy(by_uuid, uuid, fn -> view(uuid, record, epoch) end)

        view =
          if view.at != record.position do
            {_, moved} = view(uuid, record, epoch, id)
            %{moved | motion_revision: view.motion_revision + 1}
          else
            view
          end

        cost = EntityView.bytes(view)

        {{id, %{view | count: record.count}}, size + cost}
      end)

    true = bytes <= @max_view_bytes
    Map.new(entries)
  end

  defp view(uuid, record, epoch) do
    {:ok, id} = EntityView.id()
    view(uuid, record, epoch, id)
  end

  defp view(uuid, %{position: {x, y, z}, value: value, count: count}, epoch, id) do
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z, on_ground: false}

    metadata =
      EntityView.packet(EntityPackets.metadata(id, no_gravity: true, experience_value: value))

    {id, Map.merge(EntityView.new(:orb, entity, metadata, epoch), %{value: value, count: count})}
  end

  # Only append-only creation sets and transfer status change in this lifecycle.
  # The revision fences settlement as well as adoption without deep idle comparisons.
  defp stamp(cs),
    do:
      {map_size(cs.pending_awards), map_size(cs.cooking_orbs), cs.orb_transfers.revision,
       cs.orb_consumption.revision, cs.orb_bodies.revision}

  defp rotate(ids, nil), do: ids

  defp rotate(ids, cursor) do
    {before, later} = Enum.split_while(ids, &(&1 <= cursor))
    later ++ before
  end

  defp owned?(key, {x, _, z}), do: Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp retry(state, at),
    do: %{state | cooking_orbs: %{state.cooking_orbs | seen: nil, retry_at: at}}

  defp reply(nil, _), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)
  defp now, do: System.monotonic_time(:millisecond)

  defp timer(state, message, delay),
    do: Process.send_after(self(), {:resource, state.items.epoch, message}, delay)

  defp clear_job(job) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
  end
end
