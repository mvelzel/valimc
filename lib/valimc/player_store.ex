defmodule Valimc.PlayerStore do
  use GenServer, restart: :temporary, shutdown: 15_000
  require Logger

  alias Valimc.Metrics
  alias Valimc.Player.State, as: PlayerState

  @moduledoc """
  A session's player file writer (VMC-077i3): leased to the player's
  connection, it loads the file at login and writes the session's
  checkpoints and its final save, off the session's process. Its fence ends
  a stale session's lease when a new one loads.
  """
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

      {:error, {:already_started, _pid}} ->
        {:error, :session_closing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Save `snapshot`; `{:player_saved, ref, result}` follows to the store's owner."
  def checkpoint(pid, fence, snapshot, ref),
    do: GenServer.cast(pid, {:checkpoint, owner(), fence, snapshot, ref})

  def close(pid, fence, snapshot),
    do: GenServer.call(pid, {:close, owner(), fence, snapshot}, budget(pid, 5000))

  def close_session(pid, fence, snapshot),
    do: GenServer.call(pid, {:close, owner(), fence, snapshot}, budget(pid, 5000))

  # The store's owner is the player's connection; a session its group hosts
  # acts for it (`Valimc.Session.Host`).
  defp owner, do: Valimc.Session.Host.acting() || self()

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
    # No disk I/O in init: a slow read must not block the dynamic supervisor.
    {:ok,
     %{
       uuid: uuid,
       owner: owner,
       monitor: Process.monitor(owner),
       path: path(Valimc.config(:world_path, uuid), uuid),
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

  def handle_call({:close, owner, fence, snapshot}, _from, %{owner: owner} = state) do
    result = with {:ok, next} <- leased(state, fence, snapshot), do: save(state, next)
    {:stop, :normal, result, state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :not_owner}, state}

  @impl true
  def handle_cast({:checkpoint, owner, fence, snapshot, ref}, %{owner: owner} = state) do
    case leased(state, fence, snapshot) do
      {:ok, next} ->
        result = save(state, next)
        send(owner, {:player_saved, ref, result})
        {:noreply, if(result == :ok, do: %{state | snapshot: next}, else: state)}

      error ->
        send(owner, {:player_saved, ref, error})
        {:noreply, state}
    end
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  defp leased(state, fence, snapshot) when is_map(snapshot) do
    cond do
      not state.loaded -> {:error, :player_store_not_loaded}
      fence != state.fence -> {:error, :stale_player_snapshot}
      true -> {:ok, PlayerState.new(snapshot)}
    end
  end

  defp leased(_, _, _), do: {:error, :invalid_player_state}

  defp load(nil, _), do: {:ok, nil}

  defp load(path, uuid) do
    case File.open(path, [:read, :binary], fn io ->
           IO.binread(io, PlayerState.max_bytes() + 1)
         end) do
      {:ok, bytes} when is_binary(bytes) -> PlayerState.decode(bytes, uuid)
      {:error, :enoent} -> {:ok, nil}
      {:ok, :eof} -> {:error, :invalid_player_file}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save(state, snapshot) do
    result =
      with {:ok, bytes} <- PlayerState.encode(state.uuid, snapshot),
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
