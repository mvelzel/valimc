defmodule Valimc.World.ClockStore do
  use GenServer
  alias Valimc.World.ClockRecord

  @moduledoc "Linked clock I/O owner; only one immutable checkpoint is admitted by the clock owner."
  def start_link(path), do: GenServer.start_link(__MODULE__, path)
  def load(pid), do: GenServer.call(pid, :load)
  def snapshot(pid, data, owner, token), do: GenServer.cast(pid, {:save, data, owner, token})
  def flush(pid, data), do: GenServer.call(pid, {:flush, data}, 15_000)
  def path(nil), do: nil
  def path(base), do: Path.join(base, "world.clocks")
  @impl true
  def init(path), do: {:ok, path}
  @impl true
  def handle_call(:load, _, path) do
    result =
      if path do
        case File.open(path, [:read, :binary]) do
          {:ok, file} ->
            bytes = IO.binread(file, ClockRecord.max_bytes() + 1)
            File.close(file)

            if is_binary(bytes),
              do: ClockRecord.decode(bytes),
              else: {:error, :invalid_clock_file}

          {:error, :enoent} ->
            {:ok, ClockRecord.new()}

          error ->
            error
        end
      else
        {:ok, ClockRecord.new()}
      end

    {:reply, result, path}
  end

  def handle_call({:flush, data}, _, path), do: {:reply, write(path, data), path}
  @impl true
  def handle_cast({:save, data, owner, token}, path) do
    send(owner, {:clock_saved, token, write(path, data)})
    {:noreply, path}
  end

  defp write(nil, _), do: :ok

  defp write(path, data) do
    temporary = path <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    result =
      with {:ok, bytes} <- ClockRecord.encode(data),
           :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, file} <- File.open(temporary, [:write, :binary, :sync, :exclusive]) do
        written = IO.binwrite(file, bytes)
        closed = File.close(file)
        with :ok <- written, :ok <- closed, do: File.rename(temporary, path)
      end

    if result != :ok, do: File.rm(temporary)
    result
  end
end
