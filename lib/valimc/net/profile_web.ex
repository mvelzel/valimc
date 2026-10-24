defmodule Valimc.Net.ProfileWeb do
  @moduledoc """
  Loopback-only report viewer. Two fixed workers, 4 KiB request lines, 32 headers,
  a 2 second header deadline and a 2 second send timeout bound all socket work.
  Read-only bearer URLs; no filesystem paths, uploads, cookies or external assets.
  """
  use GenServer
  alias Valimc.Admin.{Profiler, ProfileReport}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:valimc, :profiler_port, 0))

    {:ok, socket} =
      :gen_tcp.listen(port, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :http_bin,
        packet_size: 4096,
        backlog: 16,
        reuseaddr: true,
        send_timeout: 2000,
        send_timeout_close: true
      ])

    {:ok, {_, bound}} = :inet.sockname(socket)
    Profiler.viewer_port(bound)
    for _ <- 1..2, do: spawn_link(fn -> accept(socket) end)
    {:ok, socket}
  end

  defp accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          serve(socket)
        rescue
          _ -> :ok
        after
          :gen_tcp.close(socket)
        end

        accept(listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end

  defp serve(socket) do
    deadline = System.monotonic_time(:millisecond) + 2000

    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, {:http_request, :GET, {:abs_path, path}, _}} ->
        if headers(socket, 32, deadline), do: respond(socket, path)

      _ ->
        :ok
    end
  end

  defp headers(_, 0, _), do: false

  defp headers(socket, left, deadline) do
    timeout = max(1, deadline - System.monotonic_time(:millisecond))

    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, :http_eoh} -> true
      {:ok, {:http_header, _, _, _, _}} -> headers(socket, left - 1, deadline)
      _ -> false
    end
  end

  defp respond(socket, path) do
    {code, type, body} = route(path)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      code,
      "\r\nContent-Type: ",
      type,
      "\r\nContent-Length: ",
      Integer.to_string(IO.iodata_length(body)),
      "\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff",
      "\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'\r\n\r\n",
      body
    ])
  end

  @doc false
  def route(path) do
    case String.split(path, "/") do
      ["", kind, id] when kind in ["r", "data"] and byte_size(id) == 32 ->
        case Profiler.report(id) do
          {:ok, data} when kind == "r" ->
            {"200 OK", "text/html; charset=utf-8", ProfileReport.html(data, "/data/" <> id)}

          {:ok, data} ->
            {"200 OK", "application/json", :json.encode(data)}

          :error ->
            missing()
        end

      _ ->
        missing()
    end
  end

  defp missing,
    do:
      {"404 Not Found", "text/plain",
       "Report expired or unknown. Run /spark health or start a new profile."}
end
