defmodule Valimc.PlayerStore do
  use GenServer, restart: :temporary, shutdown: 15_000
  require Logger
  alias Valimc.{Metrics, PlayerSnapshot}

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
          {:ok, snapshot} -> {:ok, pid, snapshot}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:already_started, _}} ->
        {:error, :session_closing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint(pid, snapshot, ref),
    do: GenServer.cast(pid, {:checkpoint, self(), snapshot, ref})

  def close(pid, snapshot), do: GenServer.call(pid, {:close, snapshot}, 5000)
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
    {:ok, %{uuid: uuid, owner: owner, monitor: ref, path: path(Valimc.config(:world_path), uuid)}}
  end

  @impl true
  def handle_call(:load, {owner, _}, %{owner: owner} = state) do
    case load(state.path, state.uuid) do
      {:ok, snapshot} -> {:reply, {:ok, snapshot}, state}
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:close, snapshot}, {owner, _}, %{owner: owner} = state) do
    result = save(state, snapshot)
    {:stop, :normal, result, state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :not_owner}, state}

  @impl true
  def handle_cast({:checkpoint, owner, snapshot, ref}, %{owner: owner} = state) do
    result = save(state, snapshot)
    send(owner, {:player_saved, ref, result})
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:stop, :normal, state}

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
