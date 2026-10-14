defmodule Valimc.Auth.HTTP do
  @moduledoc "Bounded HTTP/1.x over verified passive TLS, owned by a cold authentication worker."
  @max_body 65_536
  @max_headers 8192
  @max_chunk_metadata 8192
  def max_body, do: @max_body

  def get(url, deadline, roots \\ :system) do
    uri = URI.parse(url)
    true = uri.scheme == "https" and uri.userinfo == nil and uri.fragment == nil
    true = is_binary(uri.host) and Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, uri.host)
    port = uri.port || 443
    true = port in 1..65_535
    target = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    true = byte_size(target) <= 2048 and not Regex.match?(~r/[\x00-\x20\x7F]/, target)
    deadline = min(deadline, System.monotonic_time(:millisecond) + 5000)
    certificates = if roots == :system, do: :public_key.cacerts_get(), else: roots

    options = [
      :binary,
      active: false,
      send_timeout: remaining(deadline),
      send_timeout_close: true,
      verify: :verify_peer,
      cacerts: certificates,
      server_name_indication: String.to_charlist(uri.host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    {:ok, socket} = :ssl.connect(String.to_charlist(uri.host), port, options, remaining(deadline))

    try do
      host = uri.host <> if(port == 443, do: "", else: ":#{port}")

      :ok =
        :ssl.send(socket, [
          "GET ",
          target,
          " HTTP/1.1\r\nHost: ",
          host,
          "\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        ])

      state = %{socket: socket, deadline: deadline, buffer: <<>>, headers: 0, metadata: 0}
      {{:http_response, version, status, _}, state} = packet(state, :http_bin, :headers)
      true = version in [{1, 0}, {1, 1}] and status in 200..599
      {headers, state} = headers(state, :headers, %{})
      true = Map.get(headers, "content-encoding", "identity") == "identity"
      {body, _state} = body(status, headers, state)
      remaining(deadline)
      {:ok, status, body}
    after
      :ssl.close(socket)
    end
  rescue
    _ -> {:error, :session_unavailable}
  catch
    _, _ -> {:error, :session_unavailable}
  end

  defp remaining(deadline) do
    time = deadline - System.monotonic_time(:millisecond)
    if time <= 0, do: throw(:https_timeout)
    time
  end

  defp recv(state) do
    :ssl.recv(state.socket, 0, remaining(state.deadline))
  end

  defp packet(state, type, budget) when budget in [:headers, :metadata] do
    limit = if budget == :headers, do: @max_headers, else: @max_chunk_metadata
    left = limit - Map.fetch!(state, budget)
    if left <= 0, do: throw(:https_headers)

    case :erlang.decode_packet(type, state.buffer, packet_size: left, line_length: left) do
      {:ok, packet, tail} ->
        size = byte_size(state.buffer) - byte_size(tail)
        if size > left, do: throw(:https_headers)
        {packet, state |> Map.put(:buffer, tail) |> Map.update!(budget, &(&1 + size))}

      {:more, _} ->
        if byte_size(state.buffer) >= left, do: throw(:https_headers)
        {:ok, data} = recv(state)
        packet(%{state | buffer: state.buffer <> data}, type, budget)

      _ ->
        throw(:https_headers)
    end
  end

  defp headers(state, budget, acc) do
    case packet(state, :httph_bin, budget) do
      {:http_eoh, state} ->
        {acc, state}

      {{:http_header, _, _, name, value}, state} ->
        name = String.downcase(name)

        if name in ["content-length", "transfer-encoding", "content-encoding"] do
          if Map.has_key?(acc, name), do: throw(:https_duplicate_header)
          value = String.trim(value)
          value = if name == "content-length", do: value, else: String.downcase(value)
          headers(state, budget, Map.put(acc, name, value))
        else
          # Repeated informational headers are legal and do not determine framing.
          # Their bytes still consume the cumulative header budget.
          headers(state, budget, acc)
        end

      _ ->
        throw(:https_headers)
    end
  end

  defp body(204, _, state), do: {<<>>, state}
  defp body(304, _, state), do: {<<>>, state}

  defp body(_, headers, state) do
    case {headers["transfer-encoding"], headers["content-length"]} do
      {nil, nil} ->
        closed_body(state, [], 0)

      {nil, length} ->
        true = Regex.match?(~r/\A[0-9]{1,10}\z/, length)
        size = String.to_integer(length)
        true = size <= @max_body
        exact(state, size)

      {"chunked", nil} ->
        chunks(state, [], 0)

      _ ->
        throw(:https_framing)
    end
  end

  defp exact(state, size) do
    if byte_size(state.buffer) >= size do
      <<body::binary-size(^size), tail::binary>> = state.buffer
      {body, %{state | buffer: tail}}
    else
      {:ok, data} = recv(state)
      exact(%{state | buffer: state.buffer <> data}, size)
    end
  end

  defp closed_body(state, parts, count) do
    count = count + byte_size(state.buffer)
    if count > @max_body, do: throw(:https_body)
    parts = [state.buffer | parts]

    case recv(state) do
      {:ok, data} -> closed_body(%{state | buffer: data}, parts, count)
      {:error, :closed} -> {parts |> Enum.reverse() |> IO.iodata_to_binary(), state}
      _ -> throw(:https_body)
    end
  end

  defp chunks(state, parts, count) do
    {line, state} = chunk_line(state)
    # Extensions are bounded with the line; the hex size remains strict.
    [number | _] = String.split(line, ";", parts: 2)
    true = Regex.match?(~r/\A[0-9a-fA-F]{1,8}\z/, number)
    size = String.to_integer(number, 16)
    true = count + size <= @max_body

    if size == 0 do
      {_trailers, state} = headers(state, :metadata, %{})
      {parts |> Enum.reverse() |> IO.iodata_to_binary(), state}
    else
      {part, state} = exact(state, size)
      {"\r\n", state} = exact(state, 2)
      chunks(state, [part | parts], count + size)
    end
  end

  defp chunk_line(state) do
    left = @max_chunk_metadata - state.metadata

    case :binary.match(state.buffer, "\r\n") do
      {length, 2} when length + 2 <= left ->
        <<line::binary-size(^length), "\r\n", tail::binary>> = state.buffer
        {line, %{state | buffer: tail, metadata: state.metadata + length + 2}}

      :nomatch when byte_size(state.buffer) < left ->
        {:ok, data} = recv(state)
        chunk_line(%{state | buffer: state.buffer <> data})

      _ ->
        throw(:https_chunk_metadata)
    end
  end
end
