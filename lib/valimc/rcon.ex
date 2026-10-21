defmodule Valimc.Rcon do
  @moduledoc """
  RCON (VMC-010g), vanilla's `RconThread` and `RconClient`: off unless
  `VALIMC_RCON=true`, on `VALIMC_RCON_PORT` (25575) at the server's address,
  and only with a `VALIMC_RCON_PASSWORD`.

  A packet is a little-endian length, request id and type, then a
  null-terminated string; vanilla takes 10 to 1,460 bytes. Type 3 logs in with
  the password (answered as type 2 with the request id, or id -1 when it is
  wrong), type 2 runs a command as the Rcon source at permission level 4 and
  answers its output (each message's text, without separators) in type 0
  packets of at most 4,096 characters, and any other type answers "Unknown
  request". Commands before a login answer the login failure. At most
  `rcon_clients` (16) are connected at once; each client runs its commands
  itself, one at a time.
  """
  use GenServer
  require Logger

  @max_packet 1460

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The port it listens on (tests listen on port 0)."
  def port, do: GenServer.call(__MODULE__, :port)

  @impl true
  def init(opts) do
    password = Keyword.get(opts, :password, Valimc.config(:rcon_password)) || ""
    port = Keyword.get(opts, :port, Valimc.config(:rcon_port))
    ip = Valimc.config(:ip)

    cond do
      password == "" ->
        Logger.warning("No rcon password set in server.properties, rcon disabled!")
        :ignore

      not is_integer(port) or port < 0 or port > 65_535 ->
        Logger.warning(
          "Invalid rcon port #{inspect(port)} found in server.properties, rcon disabled!"
        )

        :ignore

      true ->
        case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, ip: ip, reuseaddr: true]) do
          {:ok, socket} ->
            {:ok, {_, bound}} = :inet.sockname(socket)

            {:ok, clients} =
              DynamicSupervisor.start_link(
                strategy: :one_for_one,
                max_children: Valimc.config(:rcon_clients)
              )

            parent = self()
            spawn_link(fn -> accept(socket, clients, password, parent) end)
            Logger.info("RCON running on #{:inet.ntoa(ip)}:#{bound}")
            {:ok, %{socket: socket, port: bound}}

          {:error, reason} ->
            Logger.warning(
              "Unable to initialise RCON on #{:inet.ntoa(ip)}:#{port}: #{inspect(reason)}"
            )

            :ignore
        end
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept(listener, clients, password, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spec = %{
          id: :client,
          start: {Task, :start_link, [fn -> client(password) end]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(clients, spec) do
          {:ok, pid} ->
            case :gen_tcp.controlling_process(socket, pid) do
              :ok -> send(pid, {:socket, socket})
              _ -> :gen_tcp.close(socket)
            end

          _full ->
            :gen_tcp.close(socket)
        end

        accept(listener, clients, password, parent)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("RCON accept failed: #{inspect(reason)}")
        accept(listener, clients, password, parent)
    end
  end

  defp client(password) do
    receive do
      {:socket, socket} ->
        try do
          serve(socket, password, false)
        after
          :gen_tcp.close(socket)
        end
    after
      5000 -> :ok
    end
  end

  defp serve(socket, password, authed) do
    with {:ok, <<length::little-signed-32>>} <- :gen_tcp.recv(socket, 4),
         true <- length + 4 >= 10 and length + 4 <= @max_packet,
         {:ok, body} <- :gen_tcp.recv(socket, length) do
      # `intFromByteArray` reads a missing int as 0.
      padded = body <> <<0::64>>
      <<request::little-signed-32, type::little-signed-32, _::binary>> = padded

      text =
        body
        |> binary_part(min(8, byte_size(body)), max(byte_size(body) - 8, 0))
        |> :binary.split(<<0>>)
        |> hd()

      case type do
        3 ->
          if text != "" and equal?(text, password) do
            send_packet(socket, request, 2, "")
            serve(socket, password, true)
          else
            send_packet(socket, -1, 2, "")
            serve(socket, password, false)
          end

        2 when authed ->
          output =
            try do
              Valimc.Commands.execute_rcon(text)
            rescue
              exception -> "Error executing: #{text} (#{Exception.message(exception)})"
            end

          for chunk <- chunks(output), do: send_packet(socket, request, 0, chunk)
          serve(socket, password, true)

        2 ->
          send_packet(socket, -1, 2, "")
          serve(socket, password, false)

        other ->
          hex = Integer.to_string(Bitwise.band(other, 0xFFFFFFFF), 16) |> String.downcase()
          send_packet(socket, request, 0, "Unknown request #{hex}")
          serve(socket, password, authed)
      end
    else
      _ -> :ok
    end
  end

  # `sendCmdResponse`: pieces of at most 4,096 characters, at least one.
  defp chunks(""), do: [""]

  defp chunks(text) do
    text |> String.codepoints() |> Enum.chunk_every(4096) |> Enum.map(&Enum.join/1)
  end

  defp send_packet(socket, request, type, text) do
    :gen_tcp.send(socket, [
      <<byte_size(text) + 10::little-signed-32, request::little-signed-32,
        type::little-signed-32>>,
      text,
      <<0, 0>>
    ])
  end

  # A comparison whose time does not depend on where the texts differ.
  defp equal?(a, b), do: :crypto.hash_equals(:crypto.hash(:sha256, a), :crypto.hash(:sha256, b))
end
