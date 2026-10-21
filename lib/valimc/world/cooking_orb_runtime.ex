defmodule Valimc.World.CookingOrbRuntime do
  @moduledoc "Bounded local/remote XP proposals; durable ACK before observation and receipt."
  alias Valimc.Protocol.EntityPackets

  alias Valimc.World.{
    Jobs,
    CookingOrbs,
    CookingOrbTransfers,
    CookingOrbBodies,
    EntityView,
    RegionData
  }

  defstruct seen: nil,
            retry_at: nil,
            cursor: nil,
            ledger: %{},
            views: %{},
            revision: 0,
            consumption_revision: 0,
            body_revision: 0,
            receipt: nil,
            delivery_cursor: nil,
            delivery_seen: nil,
            delivery_retry_at: nil

  @max_view_bytes 1_048_576

  def tick(state, now) do
    runtime = state.cooking_orbs
    cs = state.containers

    cond do
      not state.item_storage_enabled or Jobs.running?(state.jobs, :orb_plan) or
          RegionData.write_busy(state) != nil ->
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
        {:reply, Valimc.Error.retry(:stale_owner), state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      not is_binary(bytes) or byte_size(bytes) > CookingOrbTransfers.max_request_bytes() ->
        {:reply, {:error, :invalid_cooking_orb_transfer}, state}

      not is_integer(deadline) or now() >= deadline ->
        {:reply, {:error, :expired_cooking_orb_transfer}, state}

      RegionData.write_busy(state) != nil or Jobs.running?(state.jobs, :orb_plan) ->
        {:reply, Valimc.Error.retry(:item_storage_busy), state}

      true ->
        next = start(state, now(), {:adopt, bytes}, from, deadline)

        if Jobs.running?(next.jobs, :orb_plan),
          do: {:noreply, next},
          else: {:reply, {:error, :cooking_orb_workers_busy}, next}
    end
  end

  # The plan runs as the owner's `:orb_plan` job; a crash is a failed plan.
  defp start(state, now, operation, from, deadline) do
    epoch = state.items.epoch
    containers = state.containers
    runtime = state.cooking_orbs
    key = state.key

    work = fn ->
      case operation do
        :scan -> plan(containers, key, epoch, runtime)
        {:adopt, bytes} -> plan_adoption(containers, key, epoch, runtime, bytes)
      end
    end

    data = %{
      ledger: containers.cooking_orbs,
      transfers: containers.orb_transfers,
      consumption: containers.orb_consumption,
      bodies: containers.orb_bodies,
      stamp: stamp(containers),
      from: from,
      deadline: deadline
    }

    case RegionData.start_job(state, :orb_plan, work,
           supervisor: Valimc.ItemWorkers,
           deadline: 2000,
           data: data
         ) do
      {:ok, state} -> put_in(state.cooking_orbs.retry_at, nil)
      {:error, _} -> retry(state, now + 100)
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
  end

  @doc "The `:orb_plan` job reported (`job` is its data)."
  def done(state, job, result) do
    if current?(state, job),
      do: accept(state, job, result),
      else: reject(state, job, :stale_cooking_orb_plan)
  end

  defp current?(state, job),
    do:
      not RegionData.planning?(state) and state.containers.cooking_orbs === job.ledger and
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

  @doc "The `:orb_plan` job overran (`:timeout`) or died."
  def failed(state, job, :timeout) do
    reply(job.from, {:error, :cooking_orb_plan_timeout})
    {:noreply, retry(state, now() + 1000)}
  end

  def failed(state, job, _reason) do
    reply(job.from, {:error, :cooking_orb_plan_failed})
    {:noreply, retry(state, now() + 100)}
  end

  @doc "The owner stops: a waiting adoption hears so."
  def terminate(state) do
    with %{data: job} <- Jobs.get(state.jobs, :orb_plan),
         do: reply(job.from, {:error, :cooking_orb_owner_stopped})
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
end
