defmodule Valimc.PlayerStore do
  use GenServer, restart: :temporary, shutdown: 15_000
  require Logger
  alias Valimc.{Metrics, PlayerSnapshot, PlayerTransfers, World}
  alias Valimc.World.Region

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
        case GenServer.call(pid, :load) do
          {:ok, snapshot, fence} -> {:ok, pid, snapshot, fence}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:already_started, _}} ->
        {:error, :session_closing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint(pid, fence, snapshot, ref),
    do: GenServer.cast(pid, {:checkpoint, self(), fence, snapshot, ref})

  def prepare_transfer(pid, fence, before, after_snapshot, key, records, ref),
    do: GenServer.cast(pid, {:prepare, self(), fence, before, after_snapshot, key, records, ref})

  def complete_transfer(pid, fence, ref),
    do: GenServer.cast(pid, {:complete, self(), fence, ref})

  def close(pid, fence, snapshot), do: GenServer.call(pid, {:close, fence, snapshot}, 5000)
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
       path: path(Valimc.config(:world_path), uuid),
       loaded: false,
       snapshot: nil,
       fence: make_ref()
     }}
  end

  @impl true
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
    result =
      with :ok <- source_guard(state, fence),
           false <- pending?(state),
           {:ok, next} <-
             PlayerTransfers.prepare(
               state.uuid,
               sequence(state),
               before,
               after_snapshot,
               key,
               records
             ),
           do: {:ok, next}

    case result do
      {:ok, next} -> commit_transfer(state, next, ref)
      true -> transfer_reply(state, ref, {:error, :transfer_pending})
      error -> transfer_reply(state, ref, error)
    end
  end

  def handle_cast({:complete, owner, fence, ref}, %{owner: owner} = state) do
    with :ok <- source_guard(state, fence),
         :ok <- destination_proof(state) do
      commit_transfer(state, %{state.snapshot | outbox: nil}, ref)
    else
      error -> transfer_reply(state, ref, error)
    end
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:stop, :normal, state}

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

  defp destination_proof(state) do
    with {:ok, key, request, digest} <-
           PlayerSnapshot.transfer_request(state.uuid, state.snapshot),
         {:ok, owner} <- World.item_owner(key),
         {:ok, {^key, receipt}} <- Region.item_transfer_receipt(owner, state.uuid) do
      if receipt == %{sequence: request.sequence, digest: digest},
        do: :ok,
        else: {:error, :transfer_receipt_conflict}
    else
      {:error, :no_pending_transfer} = error -> error
      {:error, :missing_transfer_receipt} -> {:error, :transfer_not_applied}
      {:error, :transfer_storage_disabled} -> {:error, :transfer_destination_ephemeral}
      _ -> {:error, :transfer_destination_unavailable}
    end
  catch
    :exit, _ -> {:error, :transfer_destination_unavailable}
  end

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

  defp write(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", bytes, [:binary, :sync]),
         :ok <- File.rename(path <> ".tmp", path) do
      Metrics.add(:player_saves)
      :ok
    end
  end
end
