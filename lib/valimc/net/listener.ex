defmodule Valimc.Net.Listener do
  @moduledoc """
  The game port: one listen socket and `:acceptors` acceptor processes. An
  accept error other than a closed socket (out of descriptors, `system_limit`,
  an aborted connection) backs off and accepts again, so a burst of
  connections never stops the listener or the application (VMC-077a).
  """
  use GenServer
  require Logger

  # Back-off after a failed accept: doubles from 10 ms up to 1 s; a success resets it.
  @first_backoff 10
  @max_backoff 1000

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

    for _ <- 1..Valimc.config(:acceptors),
        do: spawn_link(fn -> accept_loop(fn -> :gen_tcp.accept(socket) end, &start/1) end)

    Logger.info(
      "ValiMC #{Valimc.version()} listening on #{:inet.ntoa(Valimc.config(:ip))}:#{port}"
    )

    {:ok, %{socket: socket, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @doc """
  Accept with `accept` and hand each socket to `start` until the listen socket
  closes; errors back off and retry. Shared by RCON.
  """
  def accept_loop(accept, start, backoff \\ nil) do
    case accept.() do
      {:ok, socket} ->
        start.(socket)
        accept_loop(accept, start, nil)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        backoff = if backoff, do: min(backoff * 2, @max_backoff), else: @first_backoff
        if backoff == @first_backoff, do: Logger.warning("Accept failed: #{inspect(reason)}")
        Valimc.Data.Metrics.add(:accept_errors)
        Process.sleep(backoff)
        accept_loop(accept, start, backoff)
    end
  end

  defp start(socket) do
    case DynamicSupervisor.start_child(
           Valimc.ConnectionSupervisor,
           {Valimc.Net.Connection, socket}
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
  end
end
