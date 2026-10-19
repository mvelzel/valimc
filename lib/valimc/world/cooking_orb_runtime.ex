defmodule Valimc.World.CookingOrbRuntime do
  @moduledoc "Local XP installation on bounded workers, durable ACK before observation; pickup remains inactive."
  alias Valimc.Protocol.EntityPackets
  alias Valimc.World.{CookingOrbs, Items, Store}
  defstruct job: nil, seen: nil, retry_at: nil, cursor: nil, ledger: %{}, views: %{}
  @max_view_bytes 1_048_576

  def tick(state, now) do
    runtime = state.cooking_orbs
    stamp = stamp(state.containers)

    cond do
      not state.item_storage_enabled or runtime.job != nil or state.item_pending != nil ->
        state

      is_integer(runtime.retry_at) and now < runtime.retry_at ->
        state

      runtime.ledger == state.containers.cooking_orbs and
          (map_size(state.containers.pending_awards) == map_size(runtime.ledger) or
             (runtime.seen == stamp and runtime.retry_at == nil)) ->
        state

      true ->
        start(state, now)
    end
  end

  defp start(state, now) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    containers = state.containers
    runtime = state.cooking_orbs
    key = state.key

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result = plan(containers, key, epoch, runtime)
           send(owner, {:resource, epoch, {:cooking_orb_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        job = %{
          worker: worker,
          token: token,
          monitor: Process.monitor(worker),
          timer: timer(state, {:cooking_orb_deadline, token}, 2000),
          ledger: containers.cooking_orbs,
          stamp: stamp(containers)
        }

        %{state | cooking_orbs: %{runtime | job: job, retry_at: nil}}

      {:error, _} ->
        retry(state, now + 100)
    end
  end

  @doc false
  def plan(containers, key, epoch, runtime) do
    if runtime.ledger != containers.cooking_orbs do
      {:refresh, publication(containers.cooking_orbs, runtime.views, epoch)}
    else
      ids = containers.pending_awards |> Map.keys() |> Enum.sort()

      {before, after_cursor} =
        if runtime.cursor == nil,
          do: {[], ids},
          else: Enum.split_while(ids, &(&1 <= runtime.cursor))

      id =
        Enum.find(after_cursor ++ before, fn id ->
          not Map.has_key?(containers.cooking_orbs, id) and
            owned?(key, containers.pending_awards[id].position)
        end)

      if id do
        case CookingOrbs.materialize(containers, key, id) do
          {:ok, proposed, :materialized} ->
            {:install, id, containers.pending_awards[id], proposed.cooking_orbs[id],
             publication(proposed.cooking_orbs, runtime.views, epoch)}

          {:error, reason} ->
            {:refused, id, reason}
        end
      else
        :idle
      end
    end
  rescue
    _ -> {:error, :orb_plan_failed}
  end

  def result(state, worker, token, result) do
    case state.cooking_orbs.job do
      %{worker: ^worker, token: ^token} = job ->
        clear_job(job)
        state = put_in(state.cooking_orbs.job, nil)
        accept(state, job, result)

      _ ->
        {:noreply, state}
    end
  end

  defp accept(state, job, {:refresh, views}) do
    if state.containers.cooking_orbs === job.ledger do
      {:noreply, publish(state, job.ledger, views)}
    else
      {:noreply, retry(state, now() + 100)}
    end
  end

  defp accept(state, job, {:install, id, award, records, views}) do
    if state.item_pending == nil and state.containers.pending_awards[id] === award and
         state.containers.cooking_orbs === job.ledger do
      # Rebase only the orb delta. The I/O owner validates the current combined
      # snapshot, including slot/receipt/timer changes that occurred during planning.
      containers = %{state.containers | cooking_orbs: Map.put(job.ledger, id, records)}
      token = make_ref()

      Store.commit_containers(
        state.store,
        state.store_lease,
        containers,
        {self(), state.items.epoch},
        token
      )

      pending = %{
        kind: :cooking_orbs,
        phase: :writing,
        token: token,
        from: nil,
        containers: containers,
        views: views,
        id: id,
        timer: timer(state, {:item_commit_deadline, token}, 5000)
      }

      {:noreply, %{state | item_pending: pending}}
    else
      {:noreply, retry(state, now() + 100)}
    end
  end

  defp accept(state, job, :idle),
    do:
      {:noreply, %{state | cooking_orbs: %{state.cooking_orbs | seen: job.stamp, retry_at: nil}}}

  defp accept(state, _job, {:refused, id, _}),
    do: {:noreply, retry(put_in(state.cooking_orbs.cursor, id), now() + 1000)}

  defp accept(state, _job, {:error, _}), do: {:noreply, retry(state, now() + 1000)}

  def saved(state, result) do
    pending = state.item_pending
    Process.cancel_timer(pending.timer)
    state = %{state | item_pending: nil}

    case result do
      :ok ->
        state = %{
          state
          | containers: pending.containers,
            cooking: %{state.cooking | dirty: false},
            cooking_orbs: %{state.cooking_orbs | cursor: pending.id, seen: nil, retry_at: nil}
        }

        {:noreply, publish(state, pending.containers.cooking_orbs, pending.views)}

      {:error, :invalid_container_snapshot} ->
        # A concurrent slot change may fill the shared byte budget. No file was
        # written, no effects were published, and the original award stays pending.
        {:noreply, retry(put_in(state.cooking_orbs.cursor, pending.id), now() + 1000)}

      {:error, reason} ->
        {:stop, {:cooking_orb_storage_failed, reason}, state}
    end
  end

  def expired(state, token) do
    case state.cooking_orbs.job do
      %{token: ^token} = job ->
        clear_job(job)
        Process.exit(job.worker, :kill)
        {:noreply, retry(put_in(state.cooking_orbs.job, nil), now() + 1000)}

      _ ->
        {:noreply, state}
    end
  end

  def down(state) do
    clear_job(state.cooking_orbs.job)
    {:noreply, retry(put_in(state.cooking_orbs.job, nil), now() + 100)}
  end

  def terminate(runtime) do
    if runtime.job do
      clear_job(runtime.job)
      Process.exit(runtime.job.worker, :kill)
    end
  end

  @doc false
  def shutdown_containers(state, pending) do
    writer = state.store
    epoch = state.items.epoch
    token = pending.token
    # Shutdown may overtake the ACK. A rejected rebased snapshot must flush current
    # timers; a successful one must never be followed by its pre-orb predecessor.
    receive do
      {:resource, ^epoch, {:containers_saved, ^writer, ^token, :ok}} ->
        pending.containers

      {:resource, ^epoch,
       {:containers_saved, ^writer, ^token, {:error, :invalid_container_snapshot}}} ->
        state.containers

      {:resource, ^epoch, {:containers_saved, ^writer, ^token, {:error, _}}} ->
        nil
    after
      5000 -> nil
    end
  end

  defp publish(state, ledger, %{views: views, rows: rows}) do
    # This staging ledger only grows. Owner replacement destroys its entire table.
    # Future consumption/motion must explicitly retire/revise these observations.
    :ets.insert(state.item_publication, rows)
    %{state | cooking_orbs: %{state.cooking_orbs | ledger: ledger, views: views}}
  end

  defp publication(ledger, existing, epoch) do
    views = views(ledger, existing, epoch)

    rows =
      views
      |> Enum.group_by(fn {_, view} -> view.chunk end)
      |> Enum.map(fn {chunk, entries} -> {{:orbs, chunk}, epoch, Map.new(entries)} end)

    %{views: views, rows: rows}
  end

  defp views(ledger, existing, epoch) do
    by_uuid = Map.new(existing, fn {id, view} -> {view.uuid, {id, view}} end)
    records = for {_, orbs} <- ledger, {uuid, record} <- orbs, do: {uuid, record}
    true = length(records) <= CookingOrbs.max_records()

    {entries, bytes} =
      Enum.map_reduce(records, 0, fn {uuid, record}, size ->
        {id, view} = Map.get_lazy(by_uuid, uuid, fn -> view(uuid, record, epoch) end)

        cost =
          Enum.sum(
            for packet <- [view.spawn, view.metadata, view.position, view.motion],
                do: Items.packet_bytes(packet)
          )

        {{id, view}, size + cost}
      end)

    true = bytes <= @max_view_bytes
    Map.new(entries)
  end

  defp view(uuid, %{position: {x, y, z}, value: value, count: count}, epoch) do
    id = System.unique_integer([:positive])
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z, on_ground: false}

    {id,
     %{
       uuid: uuid,
       epoch: epoch,
       entity_id: id,
       ownership_generation: 0,
       metadata_revision: 1,
       motion_revision: 1,
       value: value,
       count: count,
       chunk: Valimc.World.chunk_key(x, z),
       at: {x, y, z},
       spawn: packet(EntityPackets.spawn_experience_orb(entity)),
       metadata: packet(EntityPackets.metadata(id, no_gravity: true, experience_value: value)),
       position: packet(EntityPackets.position(entity)),
       motion: packet(EntityPackets.motion(id, {0.0, 0.0, 0.0}))
     }}
  end

  defp packet({id, body}), do: {id, IO.iodata_to_binary(body)}
  defp stamp(containers), do: {containers.pending_awards, containers.cooking_orbs}
  defp owned?(key, {x, _, z}), do: Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp retry(state, at),
    do: %{state | cooking_orbs: %{state.cooking_orbs | seen: nil, retry_at: at}}

  defp now, do: System.monotonic_time(:millisecond)

  defp timer(state, message, delay),
    do: Process.send_after(self(), {:resource, state.items.epoch, message}, delay)

  defp clear_job(job) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
  end
end
