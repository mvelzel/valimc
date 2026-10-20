defmodule Valimc.World.Region do
  use GenServer
  @moduledoc "Simulation lifecycle owner; storage resources remain separate from its tick state."
  alias Valimc.World.{
    BlockBatch,
    CookingOrbTransfers,
    RegionData,
    TickClock,
    TickPipeline
  }

  def start_link({key, token}),
    do:
      GenServer.start_link(__MODULE__, {key, token},
        name: {:via, Registry, {Valimc.RegionRegistry, key}}
      )

  def child_spec({key, token}),
    do: %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [{key, token}]},
      restart: :temporary,
      shutdown: 20_000
    }

  def flush(pid), do: GenServer.call(pid, :flush, 15_000)

  @doc "Run `ticks` region ticks now, in order (deterministic tests; `:manual` owners)."
  def step({pid, _epoch}, ticks \\ 1), do: GenServer.call(pid, {:step, ticks}, 10_000)

  @doc "Read one owner-local block revision; this observation does not authorize later mutations."
  def observe_blocks(owner, positions, expected_revision \\ :any)

  def observe_blocks({pid, epoch}, positions, expected_revision)
      when is_pid(pid) and is_reference(epoch) do
    if RegionData.valid_block_query?(positions, expected_revision) do
      GenServer.call(pid, {:observe_blocks, epoch, positions, expected_revision}, 250)
    else
      {:error, :invalid_block_query}
    end
  catch
    :exit, {:timeout, _} -> {:error, :block_query_timeout}
    :exit, _ -> {:error, :region_unavailable}
  end

  def observe_blocks(_, _, _), do: {:error, :invalid_block_query}

  @doc "Observe bounded native column heights at the same fence as block observations."
  def observe_columns(owner, columns, expected_revision \\ :any)

  def observe_columns({pid, epoch}, columns, expected_revision)
      when is_pid(pid) and is_reference(epoch) do
    if RegionData.valid_column_query?(columns, expected_revision) do
      GenServer.call(pid, {:observe_columns, epoch, columns, expected_revision}, 250)
    else
      {:error, :invalid_column_query}
    end
  catch
    :exit, {:timeout, _} -> {:error, :column_query_timeout}
    :exit, _ -> {:error, :region_unavailable}
  end

  def observe_columns(_, _, _), do: {:error, :invalid_column_query}

  @doc "Authorize one menu operation on the block owner; replies are ordered with its block events."
  def request_table({pid, epoch}, connection, ref, position, grant)
      when is_pid(pid) and is_reference(epoch) and is_pid(connection) and is_reference(ref) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} ->
        if size <= Valimc.config(:max_mailbox) do
          send(pid, {:table_request, epoch, connection, ref, position, grant})
          :ok
        else
          {:error, :table_owner_unavailable}
        end

      _ ->
        {:error, :table_owner_unavailable}
    end
  end

  @doc "Retire only the specified connection's current view in this owner incarnation."
  def unsubscribe_container({pid, epoch}, connection, ref)
      when is_pid(pid) and is_reference(epoch) and is_pid(connection) and is_reference(ref) do
    send(pid, {:resource, epoch, {:container_unsubscribe, connection, ref}})
    :ok
  end

  @doc """
  Commit a prepared owner-local block batch if the observation it was planned on
  (`revision`: an observation's section `fence`, or its region revision) is still
  current. Returns the new region revision. No cross-owner atomicity.
  """
  def set_blocks({pid, epoch}, revision, edits)
      when is_pid(pid) and is_reference(epoch) and (is_map(revision) or is_integer(revision)) do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         do: GenServer.call(pid, {:set_blocks, epoch, revision, batch}, 1000)
  catch
    :exit, {:timeout, _} -> {:error, :block_commit_uncertain}
    :exit, _ -> {:error, :region_unavailable}
  end

  def set_blocks(_, _, _), do: {:error, :invalid_block_batch}

  @doc "Internal creative placement commit; caller must freshly admit its player and held item."
  def place_block({pid, epoch}, revision, %BlockBatch{} = batch, deadline)
      when is_pid(pid) and is_reference(epoch) and (is_map(revision) or is_integer(revision)) and
             is_integer(deadline) do
    GenServer.call(pid, {:place_block, epoch, revision, batch, deadline}, 1000)
  catch
    :exit, {:timeout, _} -> {:error, :block_commit_uncertain}
    :exit, _ -> {:error, :region_unavailable}
  end

  def place_block(_, _, _, _), do: {:error, :invalid_placement}
  @doc "One fresh creative destruction through the owner, including its owned metadata journal."
  def destroy_block({pid, epoch}, revision, position, deadline) do
    GenServer.call(pid, {:destroy_block, epoch, revision, position, deadline}, 1000)
  catch
    :exit, {:timeout, _} -> {:error, :block_commit_uncertain}
    :exit, _ -> {:error, :region_unavailable}
  end

  @doc """
  The `block_entity_data` packet of a live imported block entity at `position`
  (`{:ok, packet | nil}`): a refused change resends it after the block, since
  the client dropped the block entity when it predicted the change (VMC-021e1).
  """
  def block_entity_update({pid, epoch}, position) do
    GenServer.call(pid, {:block_entity_update, epoch, position}, 250)
  catch
    :exit, _ -> {:ok, nil}
  end

  @doc "Send current clicked/adjacent corrections from the same sender as owner block publications."
  def correct_blocks({pid, epoch}, positions, connection) when is_pid(connection) do
    GenServer.call(pid, {:correct_blocks, epoch, positions, connection}, 250)
  catch
    :exit, _ -> {:error, :region_unavailable}
  end

  @doc "Reserve currently owned blocks for a short mining commit; the token is invalid after mutation/restart."
  def reserve_mining({pid, epoch}, positions),
    do: GenServer.call(pid, {:reserve_mining, epoch, positions}, 250)

  @doc "Keep the original block fence alive during a long attempt; renewal cannot recreate it."
  def renew_mining({pid, epoch}, permit),
    do: GenServer.call(pid, {:renew_mining, epoch, permit}, 250)

  @doc "Retire an uncommitted attempt without waiting for reservation expiry."
  def release_mining({pid, epoch}, permit),
    do: GenServer.call(pid, {:release_mining, epoch, permit}, 250)

  @doc "Internal inbox: the caller must have durably prepared and fenced the player's mining intent."
  def apply_mining_transfer({pid, epoch}, transfer),
    do: GenServer.call(pid, {:mining_transfer, epoch, transfer}, 6000)

  @doc "Fence the exact prepared placement context on its existing block owner."
  def reserve_placement({pid, epoch}, revision, expected),
    do: GenServer.call(pid, {:reserve_placement, epoch, revision, expected}, 250)

  def release_placement({pid, epoch}, permit),
    do: GenServer.call(pid, {:release_placement, epoch, permit}, 250)

  @doc "Internal inbox: delivery follows durable, leased source consumption."
  def apply_placement_transfer({pid, epoch}, transfer),
    do: GenServer.call(pid, {:placement_transfer, epoch, transfer}, 6000)

  # Scene-only API: these operations must never consume a player inventory.
  def create_item({pid, epoch}, stack, position),
    do: GenServer.call(pid, {:create_item, epoch, stack, position}, 6000)

  def replace_item({pid, epoch, id, revision}, stack),
    do: GenServer.call(pid, {:replace_item, epoch, id, revision, stack}, 6000)

  def remove_item({pid, epoch, id, revision}),
    do: GenServer.call(pid, {:remove_item, epoch, id, revision}, 6000)

  @doc "Trusted accepted player contact; a new receipt slot is durable before this returns a grant."
  def reserve_pickup({pid, epoch}, actor, item_uuid),
    do:
      GenServer.call(
        pid,
        {:reserve_pickup, epoch, actor, item_uuid, System.monotonic_time(:millisecond) + 250},
        6000
      )

  @doc "Internal pickup inbox; delivery follows the player's durably prepared original inventory."
  def apply_pickup_transfer({pid, epoch}, request),
    do: GenServer.call(pid, {:pickup_transfer, epoch, request}, 6000)

  def release_pickup({pid, epoch}, token, source),
    do: send(pid, {:resource, epoch, {:release_pickup, token, source}})

  @doc "Trusted donor proposal; a returned grant follows durable recipient receipt admission."
  def reserve_item_merge({pid, epoch}, proposal),
    do:
      GenServer.call(
        pid,
        {:reserve_item_merge, epoch, proposal, System.monotonic_time(:millisecond) + 250},
        6000
      )

  @doc "Internal source journal; use only the request returned by reserve_item_merge/2."
  def prepare_item_merge({pid, epoch}, request),
    do: GenServer.call(pid, {:prepare_item_merge, epoch, request}, 6000)

  def apply_item_merge({pid, epoch}, request),
    do: GenServer.call(pid, {:apply_item_merge, epoch, request}, 6000)

  def owner_item_receipt({pid, epoch}, source),
    do: GenServer.call(pid, {:owner_item_receipt, epoch, source}, 2000)

  def release_item_merge({pid, epoch}, token, source),
    do: send(pid, {:resource, epoch, {:release_item_merge, token, source}})

  def item_merge_donor({pid, epoch}, uuid, recipient),
    do: GenServer.call(pid, {:item_merge_donor, epoch, uuid, recipient}, 2000)

  def apply_item_merge_counters({pid, epoch}, request, source_fence),
    do: GenServer.call(pid, {:item_merge_counters, epoch, request, source_fence}, 2000)

  @doc "Trusted same-owner pairs; reply follows one durable replacement/removal commit."
  def merge_items({pid, epoch}, pairs),
    do:
      GenServer.call(
        pid,
        {:merge_items, epoch, pairs, System.monotonic_time(:millisecond) + 250},
        6000
      )

  @doc "Trusted accepted steps; caller must supply fresh geometry and retain the returned fences."
  def advance_items({pid, epoch}, steps),
    do:
      GenServer.call(
        pid,
        {:advance_items, epoch, steps, System.monotonic_time(:millisecond) + 250},
        6000
      )

  @doc "Trusted accepted ordinary motion; coalesced persistence may roll back motion after a crash."
  def publish_item_motion({pid, epoch}, steps),
    do:
      GenServer.call(
        pid,
        {:publish_item_motion, epoch, steps, System.monotonic_time(:millisecond) + 250},
        2000
      )

  def find_item({pid, epoch}, uuid), do: GenServer.call(pid, {:find_item, epoch, uuid})

  @doc "Trusted accepted border steps; success means durable withdrawal, with asynchronous delivery."
  def handoff_items({pid, epoch}, destination, steps),
    do:
      GenServer.call(
        pid,
        {:handoff_items, epoch, destination, steps, System.monotonic_time(:millisecond) + 250},
        6000
      )

  @doc "Internal region inbox; delivery must follow a durably committed source intent."
  def apply_item_handoff({pid, epoch}, transfer),
    do: GenServer.call(pid, {:item_handoff, epoch, transfer}, 6000)

  @doc "Internal bounded XP inbox; source intent must already be durable."
  def apply_cooking_orb_spawn({pid, epoch}, bytes)
      when is_pid(pid) and is_reference(epoch) and is_binary(bytes) do
    with true <- byte_size(bytes) <= CookingOrbTransfers.max_request_bytes(),
         {:message_queue_len, size} <- Process.info(pid, :message_queue_len),
         true <- size <= Valimc.config(:max_mailbox) do
      deadline = System.monotonic_time(:millisecond) + 6000
      GenServer.call(pid, {:cooking_orb_spawn, epoch, bytes, deadline}, 7000)
    else
      _ -> {:error, :cooking_orb_inbox_unavailable}
    end
  end

  def apply_cooking_orb_spawn(_, _), do: {:error, :invalid_cooking_orb_transfer}

  # Internal inbox only; source persistence/lease fencing must precede gameplay use.
  def apply_item_transfer({pid, epoch}, transfer),
    do: GenServer.call(pid, {:item_transfer, epoch, transfer}, 6000)

  def item_transfer_receipt({pid, epoch}, source),
    do: GenServer.call(pid, {:item_transfer_receipt, epoch, source}, 2000)

  def container_transfer_receipt({pid, epoch}, source),
    do: GenServer.call(pid, {:container_transfer_receipt, epoch, source}, 2000)

  @doc "Internal action admission against the current chest and fresh player context."
  def admit_container_transfer({pid, epoch}, request, actor),
    do: GenServer.call(pid, {:admit_container_transfer, epoch, request, actor}, 6000)

  @doc "Deliver a prepared source intent; absent matching action admission permits rejection only."
  def container_transfer({pid, epoch}, request),
    do: GenServer.call(pid, {:container_transfer, epoch, request}, 6000)

  @impl true
  def init({key, token}) do
    Process.flag(:trap_exit, true)
    {:ok, %{key: key, admission: token, resource: nil}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %{key: key, admission: token}) do
    resource = RegionData.load(key)

    case Valimc.World.Directory.publish(key, token, %{
           items: resource.item_publication,
           epoch: resource.items.epoch
         }) do
      :ok ->
        clock = TickClock.new(resource.items.epoch, System.monotonic_time(:millisecond))

        # `:manual` owners (tests) tick only through `step/2`.
        timer =
          if Valimc.config(:region_ticks, key) == :timer,
            do: Process.send_after(self(), {:tick, clock.token}, 50)

        {:noreply, %{resource: resource, tick_clock: clock, tick_timer: timer}}

      {:error, reason} ->
        {:stop, reason, %{resource: resource}}
    end
  end

  @impl true
  def handle_call(:owner, _from, state),
    do: {:reply, {:ok, {self(), state.resource.items.epoch}}, state}

  # Deterministic stepping: run `ticks` pipeline ticks now, in order.
  def handle_call({:step, ticks}, _from, state) when is_integer(ticks) and ticks in 1..1200 do
    {resource, clock} =
      Enum.reduce(1..ticks, {state.resource, state.tick_clock}, fn _, {resource, clock} ->
        clock = %{clock | tick: clock.tick + 1}
        {TickPipeline.run(resource, clock.tick, System.monotonic_time(:millisecond)), clock}
      end)

    {:reply, {:ok, clock.tick}, %{state | resource: resource, tick_clock: clock}}
  end

  def handle_call(message, from, state),
    do: RegionData.handle_call(message, from, state.resource) |> wrap(state)

  @impl true
  def handle_info({:tick, token}, state) do
    now = System.monotonic_time(:millisecond)

    case TickClock.advance(state.tick_clock, token, now) do
      :stale ->
        {:noreply, state}

      {:early, clock, delay} ->
        {:noreply, schedule_tick(state, clock, delay)}

      {:ok, clock, late, delay} ->
        Valimc.Metrics.add(:region_ticks)
        Valimc.Metrics.add(:region_late_milliseconds, late)

        resource = TickPipeline.run(state.resource, clock.tick, now)
        {:noreply, schedule_tick(%{state | resource: resource}, clock, delay)}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:resource, epoch, message}, %{resource: %{items: %{epoch: epoch}}} = state),
    do: RegionData.handle_info(message, state.resource) |> wrap(state)

  def handle_info({:resource, _, _}, state), do: {:noreply, state}

  def handle_info({:table_request, _, _, _, _, _} = message, state),
    do: RegionData.handle_info(message, state.resource) |> wrap(state)

  def handle_info({:DOWN, _, :process, _, _} = message, state),
    do: RegionData.handle_info(message, state.resource) |> wrap(state)

  # Untagged/stale callbacks never select a resource or change its data.
  def handle_info(_, state), do: {:noreply, state}

  defp schedule_tick(state, clock, delay) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)
    timer = Process.send_after(self(), {:tick, clock.token}, delay)
    %{state | tick_clock: clock, tick_timer: timer}
  end

  defp wrap({:reply, reply, resource}, state), do: {:reply, reply, %{state | resource: resource}}
  defp wrap({:noreply, resource}, state), do: {:noreply, %{state | resource: resource}}
  defp wrap({:stop, reason, resource}, state), do: {:stop, reason, %{state | resource: resource}}

  @impl true
  def terminate(_reason, %{resource: nil}), do: :ok
  def terminate(reason, state), do: RegionData.terminate(reason, state.resource)
end
