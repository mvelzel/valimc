defmodule Valimc.PlayerStore do
  use GenServer, restart: :temporary, shutdown: 15_000
  require Logger
  alias Valimc.Metrics

  @moduledoc "A leased per-session pose writer; file I/O is outside socket owners."
  @keys [:x, :y, :z, :yaw, :pitch]
  @file_bytes 88

  def start_link({uuid, owner}) do
    GenServer.start_link(__MODULE__, {uuid, owner},
      name: {:via, Registry, {Valimc.PlayerStoreRegistry, uuid}}
    )
  end

  def open(uuid) do
    case DynamicSupervisor.start_child(Valimc.PlayerStoreSupervisor, {__MODULE__, {uuid, self()}}) do
      {:ok, pid} ->
        case GenServer.call(pid, :load) do
          {:ok, pose} -> {:ok, pid, pose}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:already_started, _}} ->
        {:error, :session_closing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint(pid, player, ref),
    do: GenServer.cast(pid, {:checkpoint, self(), pose(player), ref})

  def close(pid, player), do: GenServer.call(pid, {:close, pose(player)}, 5000)
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
      {:ok, pose} -> {:reply, {:ok, pose}, state}
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:close, pose}, {owner, _}, %{owner: owner} = state) do
    result = save(state, pose)
    {:stop, :normal, result, state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :not_owner}, state}

  @impl true
  def handle_cast({:checkpoint, owner, pose, ref}, %{owner: owner} = state) do
    result = save(state, pose)
    send(owner, {:player_saved, ref, result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:stop, :normal, state}

  defp load(nil, _), do: {:ok, nil}

  defp load(path, uuid) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, @file_bytes + 1) end) do
      {:ok, bytes} when is_binary(bytes) -> decode(bytes, uuid)
      {:error, :enoent} -> {:ok, nil}
      {:ok, :eof} -> {:error, :invalid_pose_file}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(<<payload::binary-size(56), checksum::binary-size(32)>>, uuid) do
    if :crypto.hash(:sha256, payload) == checksum do
      case payload do
        <<"VMCPOSE", 1, ^uuid::binary-size(16), x::float-64, y::float-64, z::float-64,
          yaw::float-32, pitch::float-32>> ->
          pose = %{x: x, y: y, z: z, yaw: yaw, pitch: pitch}
          if valid_pose?(pose), do: {:ok, pose}, else: {:error, :invalid_pose_file}

        _ ->
          {:error, :invalid_pose_file}
      end
    else
      {:error, :invalid_pose_file}
    end
  end

  defp decode(_, _), do: {:error, :invalid_pose_file}

  defp save(state, pose) do
    result =
      if valid_pose?(pose), do: write(state.path, state.uuid, pose), else: {:error, :invalid_pose}

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Metrics.add(:player_save_failures)
        Logger.error("Player pose save failed: #{inspect(reason)}")
    end

    result
  end

  defp write(nil, _, _), do: :ok

  defp write(path, uuid, pose) do
    payload =
      <<"VMCPOSE", 1, uuid::binary-size(16), pose.x::float-64, pose.y::float-64, pose.z::float-64,
        pose.yaw::float-32, pose.pitch::float-32>>

    bytes = payload <> :crypto.hash(:sha256, payload)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", bytes, [:binary, :sync]),
         :ok <- File.rename(path <> ".tmp", path) do
      Metrics.add(:player_saves)
      :ok
    end
  end
end
