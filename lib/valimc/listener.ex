defmodule Valimc.Listener do
  use GenServer
  require Logger
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)
  @impl true
  def init(_) do
    {:ok, socket} =
      :gen_tcp.listen(Valimc.config(:port), [
        :binary,
        packet: :raw,
        active: false,
        ip: Valimc.config(:ip),
        reuseaddr: true,
        nodelay: true,
        backlog: 1024,
        send_timeout: 2000,
        send_timeout_close: true
      ])

    {:ok, {_, port}} = :inet.sockname(socket)
    for _ <- 1..Valimc.config(:acceptors), do: spawn_link(fn -> accept(socket) end)

    Logger.info(
      "ValiMC #{Valimc.version()} listening on #{:inet.ntoa(Valimc.config(:ip))}:#{port}"
    )

    {:ok, %{socket: socket, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case DynamicSupervisor.start_child(
               Valimc.ConnectionSupervisor,
               {Valimc.Connection, socket}
             ) do
          {:ok, pid} ->
            case :gen_tcp.controlling_process(socket, pid) do
              :ok ->
                send(pid, :activate)

              _ ->
                :gen_tcp.close(socket)
                Process.exit(pid, :shutdown)
            end

          _ ->
            :gen_tcp.close(socket)
        end

        accept(listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end
end
