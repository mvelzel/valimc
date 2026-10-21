defmodule Valimc.PlayerStore do
  use GenServer, restart: :temporary, shutdown: 15_000
  require Logger

  alias Valimc.{
    Metrics,
    PlayerContainerTransfers,
    PlayerMiningTransfers,
    PlayerPlacementTransfers,
    PlayerPickupTransfers,
    PlayerSnapshot,
    PlayerTransfers,
    TransferDelivery,
    World
  }

  @moduledoc "A leased per-session player-state writer; serialization/I/O are outside socket owners."
  @keys [:x, :y, :z, :yaw, :pitch]

  def start_link({uuid, owner}) do
    GenServer.start_link(__MODULE__, {uuid, owner},
      name: {:via, Registry, {Valimc.PlayerStoreRegistry, uuid}}
    )
  end

  def open(uuid) do
    case DynamicSupervisor.start_child(Valimc.PlayerStoreSupervisor, {__MODULE__, {uuid, self()}}) do
      {:ok, pid} ->
        case GenServer.call(pid, :load, budget(pid, 5000)) do
          {:ok, snapshot, fence} -> {:ok, pid, snapshot, fence}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:already_started, pid}} ->
        case Registry.lookup(Valimc.PlayerStoreRegistry, uuid) do
          [{^pid, :closing}] ->
            try do
              case GenServer.call(pid, :load, budget(pid, 5000)) do
                {:ok, snapshot, fence} -> {:ok, pid, snapshot, fence}
                error -> error
              end
            catch
              :exit, _ -> {:error, :session_closing}
            end

          _ ->
            {:error, :session_closing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint(pid, fence, snapshot, ref),
    do: GenServer.cast(pid, {:checkpoint, self(), fence, snapshot, ref})

  def prepare_transfer(pid, fence, before, after_snapshot, key, records, ref),
    do: GenServer.cast(pid, {:prepare, self(), fence, before, after_snapshot, key, records, ref})

  def prepare_crafting(pid, fence, before, after_snapshot, key, records, gesture, ref),
    do:
      GenServer.cast(
        pid,
        {:prepare_crafting, self(), fence, before, after_snapshot, key, records, gesture, ref}
      )

  def prepare_death(pid, fence, before, after_snapshot, key, records, ref),
    do:
      GenServer.cast(
        pid,
        {:prepare_death, self(), fence, before, after_snapshot, key, records, ref}
      )

  # This is a trusted leased-owner operation, never a client-provided privilege.
  def prepare_creative_drop(pid, fence, snapshot, key, record, ref),
    do: GenServer.cast(pid, {:prepare_creative_drop, self(), fence, snapshot, key, record, ref})

  def complete_transfer(pid, fence, ref),
    do: GenServer.cast(pid, {:complete, self(), fence, ref})

  # The trusted player owner has already sampled the original loot/wear proposal.
  def prepare_mining(pid, fence, snapshot, intent, ref),
    do: GenServer.cast(pid, {:prepare_mining, self(), fence, snapshot, intent, ref})

  def prepare_placement(pid, fence, snapshot, intent, ref),
    do: GenServer.cast(pid, {:prepare_placement, self(), fence, snapshot, intent, ref})

  def prepare_pickup(pid, fence, snapshot, intent, ref),
    do: GenServer.cast(pid, {:prepare_pickup, self(), fence, snapshot, intent, ref})

  def prepare_container(pid, fence, snapshot, intent, ref),
    do: GenServer.cast(pid, {:prepare_container, self(), fence, snapshot, intent, ref})

  @doc "Preview the canonical next action; only preparation persists/reserves its sequence."
  def container_candidate(pid, fence, snapshot, intent, ref),
    do: GenServer.cast(pid, {:container_candidate, self(), fence, snapshot, intent, ref})

  def close(pid, fence, snapshot),
    do: GenServer.call(pid, {:close, fence, snapshot}, budget(pid, 5000))

  def close_session(pid, fence, snapshot),
    do: GenServer.call(pid, {:close_session, fence, snapshot}, budget(pid, 5000))

  # Call budgets scale like an owner's (`owner_call_scale`, VMC-073): 1 in play.
  defp budget(pid, ms), do: ms * Valimc.config(:owner_call_scale, pid)

  def pose(player), do: Map.take(player, @keys)

  def valid_pose?(pose) when is_map(pose) do
    Enum.all?(@keys, fn key ->
      value = Map.get(pose, key)
      bound = if key in [:x, :z], do: 29_999_984, else: 1_000_000
      is_float(value) and abs(value) <= bound
    end)
  end

  def valid_pose?(_), do: false

  def path(nil, _uuid), do: nil

  def path(base, <<_::128>> = uuid),
    do: Path.join([base, "players", Base.encode16(uuid, case: :lower) <> ".pose"])

  @impl true
  def init({<<_::128>> = uuid, owner}) do
    ref = Process.monitor(owner)
    # No disk I/O in init: a slow read must not block the dynamic supervisor.
    {:ok,
     %{
       uuid: uuid,
       owner: owner,
       monitor: ref,
       path: path(Valimc.config(:world_path, uuid), uuid),
       loaded: false,
       snapshot: nil,
       fence: make_ref(),
       closing: nil
     }}
  end

  @impl true
  def handle_call(:load, {owner, _}, %{closing: closing} = state) when closing != nil do
    # A destination may already have committed when its canceled job loses the reply.
    # The new session replays the same journal, with a new source lease.
    cancel_closing(closing)
    Process.demonitor(state.monitor, [:flush])
    Registry.update_value(Valimc.PlayerStoreRegistry, state.uuid, fn _ -> nil end)
    {:ok, bytes} = PlayerSnapshot.encode(state.uuid, state.snapshot)
    {:ok, snapshot} = PlayerSnapshot.decode(bytes, state.uuid)

    state = %{
      state
      | owner: owner,
        monitor: Process.monitor(owner),
        fence: make_ref(),
        closing: nil,
        snapshot: snapshot
    }

    {:reply, {:ok, snapshot, state.fence}, state}
  end

  def handle_call(:load, {owner, _}, %{owner: owner, loaded: false} = state) do
    case load(state.path, state.uuid) do
      {:ok, snapshot} ->
        {:reply, {:ok, snapshot, state.fence}, %{state | loaded: true, snapshot: snapshot}}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:load, {owner, _}, %{owner: owner} = state),
    do: {:reply, {:ok, state.snapshot, state.fence}, state}

  def handle_call({:close, fence, snapshot}, {owner, _}, %{owner: owner} = state) do
    result =
      with {:ok, next} <- checkpoint_snapshot(state, fence, snapshot), do: save(state, next)

    {:stop, :normal, result, state}
  end

  def handle_call(
        {:close_session, fence, snapshot},
        {owner, _},
        %{owner: owner, closing: nil} = state
      ) do
    # Preserve the newest accepted raw contents first. A failed cleanup prepare must
    # leave a recoverable source rather than only an older periodic checkpoint.
    next =
      if fence == state.fence and not pending?(state),
        do: Map.merge(snapshot, %{transfer_sequence: sequence(state), outbox: nil}),
        else: state.snapshot

    next = if next && valid_pose?(snapshot.pose), do: %{next | pose: snapshot.pose}, else: next

    next =
      if next && is_boolean(Map.get(snapshot, :flying)),
        do: Map.put(next, :flying, snapshot.flying),
        else: next

    next =
      if next && Valimc.PlayerMotion.valid_distance?(Map.get(snapshot, :fall_distance)),
        do:
          Map.merge(
            next,
            Map.take(snapshot, [
              :fall_distance,
              :game_mode,
              :frozen_ticks,
              :air_supply,
              :fire_ticks,
              :effects,
              :food,
              :velocity,
              :health,
              :last_death,
              :dimension,
              :death_dimension,
              :portal_cooldown,
              :seen_credits
            ])
          ),
        else: next

    with :ok <- save(state, next),
         {:ok, state} <- prepare_closing(%{state | snapshot: next}) do
      if pending?(state) do
        Registry.update_value(Valimc.PlayerStoreRegistry, state.uuid, fn _ -> :closing end)
        send(self(), {:deliver_close, state.closing.id})
        {:reply, :ok, state}
      else
        {:stop, :normal, :ok, state}
      end
    else
      {:error, _} = error -> {:stop, :normal, error, state}
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :not_owner}, state}

  @impl true
  def handle_cast({:checkpoint, owner, fence, snapshot, ref}, %{owner: owner} = state) do
    case checkpoint_snapshot(state, fence, snapshot) do
      {:ok, next} ->
        result = save(state, next)
        send(owner, {:player_saved, ref, result})
        {:noreply, if(result == :ok, do: %{state | snapshot: next}, else: state)}

      error ->
        send(owner, {:player_saved, ref, error})
        {:noreply, state}
    end
  end

  def handle_cast(
        {:prepare, owner, fence, before, after_snapshot, key, records, ref},
        %{owner: owner} = state
      ) do
    prepare_plan(state, fence, ref, fn ->
      PlayerTransfers.prepare(state.uuid, sequence(state), before, after_snapshot, key, records)
    end)
  end

  def handle_cast(
        {:prepare_death, owner, fence, before, after_snapshot, key, records, ref},
        %{owner: owner} = state
      ) do
    prepare_plan(state, fence, ref, fn ->
      PlayerTransfers.prepare_death(
        state.uuid,
        sequence(state),
        before,
        after_snapshot,
        key,
        records
      )
    end)
  end

  def handle_cast(
        {:prepare_crafting, owner, fence, before, after_snapshot, key, records, gesture, ref},
        %{owner: owner} = state
      ) do
    prepare_plan(state, fence, ref, fn ->
      Valimc.PlayerCraftingTransfers.prepare(
        state.uuid,
        sequence(state),
        before,
        after_snapshot,
        key,
        records,
        gesture
      )
    end)
  end

  def handle_cast(
        {:prepare_creative_drop, owner, fence, snapshot, key, record, ref},
        %{owner: owner} = state
      ) do
    prepare_plan(state, fence, ref, fn ->
      PlayerTransfers.prepare_creative_drop(state.uuid, sequence(state), snapshot, key, record)
    end)
  end

  def handle_cast({:prepare_mining, owner, fence, snapshot, intent, ref}, %{owner: owner} = state) do
    prepare_plan(state, fence, ref, fn ->
      PlayerMiningTransfers.prepare(state.uuid, sequence(state), snapshot, intent)
    end)
  end

  def handle_cast(
        {:prepare_placement, owner, fence, snapshot, intent, ref},
        %{owner: owner} = state
      ) do
    prepare_plan(state, fence, ref, fn ->
      PlayerPlacementTransfers.prepare(state.uuid, sequence(state), snapshot, intent)
    end)
  end

  def handle_cast({:prepare_pickup, owner, fence, snapshot, intent, ref}, %{owner: owner} = state) do
    prepare_plan(state, fence, ref, fn ->
      PlayerPickupTransfers.prepare(state.uuid, sequence(state), snapshot, intent)
    end)
  end

  def handle_cast(
        {:prepare_container, owner, fence, snapshot, intent, ref},
        %{owner: owner} = state
      ) do
    prepare_plan(state, fence, ref, fn ->
      PlayerContainerTransfers.prepare(state.uuid, sequence(state), snapshot, intent)
    end)
  end

  def handle_cast(
        {:container_candidate, owner, fence, snapshot, intent, ref},
        %{owner: owner} = state
      ) do
    result =
      with :ok <- source_guard(state, fence),
           {:ok, snapshot} <- checkpoint_snapshot(state, fence, snapshot),
           {:ok, candidate} <-
             PlayerContainerTransfers.prepare(state.uuid, sequence(state), snapshot, intent),
           do: {:ok, candidate.outbox}

    send(owner, {:container_candidate, ref, result})
    {:noreply, state}
  end

  def handle_cast({:complete, owner, fence, ref}, %{owner: owner} = state) do
    with :ok <- source_guard(state, fence),
         {:ok, result} <- destination_proof(state),
         {:ok, next} <- resolved_snapshot(state.uuid, state.snapshot, result) do
      commit_transfer(state, next, ref)
    else
      error -> transfer_reply(state, ref, error)
    end
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:deliver_close, id},
        %{closing: %{id: id, job: nil, retry_timer: nil} = closing} = state
      ) do
    case Valimc.Dimension.within(dimension(state.snapshot), fn ->
           TransferDelivery.start(self(), make_ref(), state.uuid, state.snapshot)
         end) do
      {:ok, job} -> {:noreply, %{state | closing: %{closing | job: job}}}
      error -> closing_failure(state, error)
    end
  end

  def handle_info(
        {:transfer_delivered, worker, token, result},
        %{closing: %{job: %{pid: worker, token: token} = job}} = state
      ) do
    Process.demonitor(job.monitor, [:flush])
    state = %{state | closing: %{state.closing | job: nil}}

    if TransferDelivery.completed?(state.snapshot, result) do
      with {:ok, outcome} <- destination_proof(state),
           {:ok, next} <- resolved_snapshot(state.uuid, state.snapshot, outcome),
           :ok <- save(state, next) do
        cancel_closing(state.closing)

        case prepare_closing(%{state | snapshot: next, closing: nil, fence: make_ref()}) do
          {:ok, %{closing: nil} = state} ->
            {:stop, :normal, state}

          {:ok, state} ->
            send(self(), {:deliver_close, state.closing.id})
            {:noreply, state}

          {:error, reason} ->
            {:stop, :normal, state |> close_error(reason)}
        end
      else
        error -> closing_failure(state, error)
      end
    else
      closing_failure(state, result)
    end
  end

  def handle_info(
        {:retry_close, id, token},
        %{closing: %{id: id, retry_token: token} = closing} = state
      ) do
    send(self(), {:deliver_close, id})
    {:noreply, %{state | closing: %{closing | retry_timer: nil, retry_token: nil}}}
  end

  def handle_info({:close_deadline, id}, %{closing: %{id: id}} = state),
    do: {:stop, :normal, close_error(state, :transfer_deadline)}

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{closing: %{job: %{pid: worker, monitor: ref}} = closing} = state
      ),
      do:
        closing_failure(
          %{state | closing: %{closing | job: nil}},
          Valimc.Error.retry(:region_restarting)
        )

  def handle_info(
        {:DOWN, ref, :process, owner, _},
        %{monitor: ref, owner: owner, closing: closing} = state
      )
      when closing != nil,
      do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: cancel_closing(state.closing)

  defp prepare_closing(state) do
    if pending?(state) do
      {:ok, start_closing(state)}
    else
      with {:ok, after_snapshot, key, records} <- PlayerTransfers.plan_cleanup(state.snapshot) do
        if records == [] do
          with :ok <- save(state, after_snapshot), do: {:ok, %{state | snapshot: after_snapshot}}
        else
          prepare =
            if match?(%{health: %{value: health}} when health <= 0, state.snapshot),
              do: &PlayerTransfers.prepare_death/6,
              else: &PlayerTransfers.prepare/6

          with :ok <- source_guard(state, state.fence),
               {:ok, next} <-
                 prepare.(
                   state.uuid,
                   sequence(state),
                   state.snapshot,
                   after_snapshot,
                   key,
                   records
                 ),
               :ok <- save(state, next),
               do: {:ok, start_closing(%{state | snapshot: next, fence: make_ref()})}
        end
      end
    end
  end

  defp start_closing(state) do
    id = make_ref()

    closing = %{
      id: id,
      job: nil,
      attempts: 0,
      retry_token: nil,
      retry_timer: nil,
      timer: Process.send_after(self(), {:close_deadline, id}, 10_000)
    }

    %{state | closing: closing}
  end

  defp closing_failure(state, result) do
    if TransferDelivery.retryable?(result) and state.closing.attempts < 20 do
      closing = state.closing
      token = make_ref()
      delay = min(50 * (closing.attempts + 1), 500)
      timer = Process.send_after(self(), {:retry_close, closing.id, token}, delay)

      {:noreply,
       %{
         state
         | closing: %{
             closing
             | attempts: closing.attempts + 1,
               job: nil,
               retry_token: token,
               retry_timer: timer
           }
       }}
    else
      {:stop, :normal, close_error(state, result)}
    end
  end

  defp close_error(state, reason) do
    Logger.warning("Disconnected inventory cleanup remains recoverable: #{inspect(reason)}")
    state
  end

  defp cancel_closing(nil), do: :ok

  defp cancel_closing(closing) do
    Process.cancel_timer(closing.timer)
    if closing.retry_timer, do: Process.cancel_timer(closing.retry_timer)

    if closing.job do
      Process.demonitor(closing.job.monitor, [:flush])

      if Process.whereis(Valimc.TransferWorkers),
        do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, closing.job.pid)
    end
  end

  defp sequence(state), do: if(state.snapshot, do: state.snapshot.transfer_sequence, else: 0)
  defp pending?(state), do: state.snapshot != nil and state.snapshot.outbox != nil

  defp lease_guard(state, fence) do
    cond do
      not state.loaded -> {:error, :player_store_not_loaded}
      fence != state.fence -> {:error, :stale_player_snapshot}
      true -> :ok
    end
  end

  defp source_guard(state, fence) do
    with :ok <- lease_guard(state, fence) do
      if state.path == nil, do: {:error, :transfer_storage_disabled}, else: :ok
    end
  end

  defp prepare_plan(state, fence, ref, plan) do
    result =
      with :ok <- source_guard(state, fence),
           false <- pending?(state),
           do: plan.()

    case result do
      {:ok, next} -> commit_transfer(state, next, ref)
      true -> transfer_reply(state, ref, {:error, :transfer_pending})
      error -> transfer_reply(state, ref, error)
    end
  end

  defp checkpoint_snapshot(state, fence, snapshot) when is_map(snapshot) do
    with :ok <- lease_guard(state, fence) do
      if pending?(state) do
        {:error, :transfer_pending}
      else
        {:ok, Map.merge(snapshot, %{transfer_sequence: sequence(state), outbox: nil})}
      end
    end
  end

  defp checkpoint_snapshot(_, _, _), do: {:error, :invalid_player_state}

  defp commit_transfer(state, snapshot, ref) do
    case save(state, snapshot) do
      :ok ->
        fence = make_ref()
        send(state.owner, {:player_transfer_saved, ref, {:ok, fence, snapshot}})
        {:noreply, %{state | snapshot: snapshot, fence: fence}}

      {:error, _} ->
        send(state.owner, {:player_transfer_saved, ref, {:error, :player_commit_uncertain}})
        {:stop, :normal, state}
    end
  end

  defp transfer_reply(state, ref, result) do
    send(state.owner, {:player_transfer_saved, ref, result})
    {:noreply, state}
  end

  # A pending outbox targets the snapshot's dimension (VMC-026b): a player
  # changes dimension only with no transfer pending.
  defp dimension(snapshot), do: Map.get(snapshot, :dimension, :overworld)

  # What the destination's durable receipt proves about the pending outbox.
  defp destination_proof(%{snapshot: %{outbox: outbox} = snapshot} = state) when outbox != nil,
    do: Valimc.Dimension.within(dimension(snapshot), fn -> proof(snapshot, state) end)

  defp destination_proof(_state), do: {:error, :no_pending_transfer}

  defp proof(snapshot, state) do
    operation = Valimc.Txn.Operation.of(snapshot)

    with {:ok, key, request, digest} <- operation.request(state.uuid, snapshot),
         {:ok, owner} <- World.item_owner(key),
         {:ok, {^key, receipt}} <- operation.receipt(owner, state.uuid) do
      # A reserved slot (sequence 0) records capacity, not this transfer.
      if receipt.sequence == 0,
        do: Valimc.Error.retry(:transfer_not_applied),
        else: operation.proof(key, request, digest, receipt)
    else
      {:error, missing} when missing in [:missing_transfer_receipt, :missing_container_receipt] ->
        Valimc.Error.retry(:transfer_not_applied)

      {:error, :transfer_storage_disabled} ->
        {:error, :transfer_destination_ephemeral}

      _ ->
        Valimc.Error.retry(:transfer_destination_unavailable)
    end
  catch
    :exit, _ -> Valimc.Error.retry(:transfer_destination_unavailable)
  end

  defp resolved_snapshot(uuid, snapshot, proof),
    do: Valimc.Txn.Operation.of(snapshot).resolve(uuid, snapshot, proof)

  defp load(nil, _), do: {:ok, nil}

  defp load(path, uuid) do
    case File.open(path, [:read, :binary], fn io ->
           IO.binread(io, PlayerSnapshot.max_bytes() + 1)
         end) do
      {:ok, bytes} when is_binary(bytes) -> PlayerSnapshot.decode(bytes, uuid)
      {:error, :enoent} -> {:ok, nil}
      {:ok, :eof} -> {:error, :invalid_player_file}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save(state, snapshot) do
    result =
      with {:ok, bytes} <- PlayerSnapshot.encode(state.uuid, snapshot),
           do: write(state.path, bytes)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Metrics.add(:player_save_failures)
        Logger.error("Player state save failed: #{inspect(reason)}")
    end

    result
  end

  defp write(nil, _), do: :ok

  # Group-committed with every owner's records (`Valimc.Storage.Log`); the
  # world folder is two levels up (`players/<uuid>.pose`).
  defp write(path, bytes) do
    with :ok <- Valimc.Storage.Log.commit_file(Path.dirname(Path.dirname(path)), path, bytes) do
      Metrics.add(:player_saves)
      :ok
    end
  end
end
