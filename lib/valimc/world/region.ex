defmodule Valimc.World.Region do
  use GenServer
  @moduledoc "Simulation lifecycle owner; storage resources remain separate from its tick state."
  alias Valimc.World.{BlockBatch, RegionData, TickClock}

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

  @doc "Commit a prepared owner-local block batch at an exact observed revision. No cross-owner atomicity."
  def set_blocks({pid, epoch}, revision, edits)
      when is_pid(pid) and is_reference(epoch) and is_integer(revision) and revision >= 0 do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         do: GenServer.call(pid, {:set_blocks, epoch, revision, batch}, 1000)
  catch
    :exit, {:timeout, _} -> {:error, :block_commit_uncertain}
    :exit, _ -> {:error, :region_unavailable}
  end

  def set_blocks(_, _, _), do: {:error, :invalid_block_batch}

  # Scene-only API: these operations must never consume a player inventory.
  def create_item({pid, epoch}, stack, position),
    do: GenServer.call(pid, {:create_item, epoch, stack, position}, 6000)

  def replace_item({pid, epoch, id, revision}, stack),
    do: GenServer.call(pid, {:replace_item, epoch, id, revision, stack}, 6000)

  def remove_item({pid, epoch, id, revision}),
    do: GenServer.call(pid, {:remove_item, epoch, id, revision}, 6000)

  def find_item({pid, epoch}, uuid), do: GenServer.call(pid, {:find_item, epoch, uuid})

  # Internal inbox only; source persistence/lease fencing must precede gameplay use.
  def apply_item_transfer({pid, epoch}, transfer),
    do: GenServer.call(pid, {:item_transfer, epoch, transfer}, 6000)

  def item_transfer_receipt({pid, epoch}, source),
    do: GenServer.call(pid, {:item_transfer_receipt, epoch, source}, 2000)

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
        timer = Process.send_after(self(), {:tick, clock.token}, 50)
        {:noreply, %{resource: resource, tick_clock: clock, tick_timer: timer}}

      {:error, reason} ->
        {:stop, reason, %{resource: resource}}
    end
  end

  @impl true
  def handle_call(:owner, _from, state),
    do: {:reply, {:ok, {self(), state.resource.items.epoch}}, state}

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
        {:noreply, schedule_tick(state, clock, delay)}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:resource, epoch, message}, %{resource: %{items: %{epoch: epoch}}} = state),
    do: RegionData.handle_info(message, state.resource) |> wrap(state)

  def handle_info({:resource, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, _, :process, _, _} = message, state),
    do: RegionData.handle_info(message, state.resource) |> wrap(state)

  # Untagged/stale callbacks never select a resource or change its data.
  def handle_info(_, state), do: {:noreply, state}

  defp schedule_tick(state, clock, delay) do
    Process.cancel_timer(state.tick_timer)
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
