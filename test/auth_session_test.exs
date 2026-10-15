defmodule Valimc.AuthSessionTest do
  use ExUnit.Case, async: true
  alias Valimc.Auth.{HTTP, Profile, SessionService}
  @id "12345678123456781234567812345678"
  defp json(value), do: value |> :json.encode() |> IO.iodata_to_binary()
  defp deadline(ms \\ 2000), do: System.monotonic_time(:millisecond) + ms

  defp certificate(host) do
    :public_key.pkix_test_data(%{
      root: [digest: :sha256, key: {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}],
      peer: [
        digest: :sha256,
        key: {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}},
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}]
      ]
    })
  end

  defp tls_server(response, host \\ "localhost") do
    conf = certificate(host)
    {:ok, listener} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ conf)
    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()

    pid =
      spawn(fn ->
        case :ssl.transport_accept(listener, 2000) do
          {:ok, socket} ->
            case :ssl.handshake(socket, 2000) do
              {:ok, socket} ->
                {:ok, request} = :ssl.recv(socket, 0, 2000)
                send(parent, {:tls_request, self(), request})
                response.(socket)
                :ssl.close(socket)

              _ ->
                :ssl.close(socket)
            end

          _ ->
            :ok
        end

        :ssl.close(listener)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :ssl.close(listener)
    end)

    {"https://localhost:#{port}/session", Keyword.fetch!(conf, :cacerts), pid}
  end

  test "native requested name, UUID forms and exact signed/unsigned properties" do
    properties = [
      %{name: "textures", value: "synthetic+/=", signature: "signed+/="},
      %{name: "other", value: "λ\u0000😀"}
    ]

    assert {:ok, p} =
             Profile.decode(
               json(%{id: @id, name: "IgnoredName", properties: properties}),
               "OracleOne"
             )

    assert p.name == "OracleOne"
    assert p.uuid == Base.decode16!(@id, case: :mixed)

    assert p.properties == [
             %{name: "textures", value: "synthetic+/=", signature: "signed+/="},
             %{name: "other", value: "λ\u0000😀", signature: nil}
           ]

    for properties <- [:null, []] do
      assert {:ok, %{properties: []}} =
               Profile.decode(
                 json(%{id: "12345678-1234-5678-1234-567812345678", properties: properties}),
                 "OracleOne"
               )
    end

    assert {:ok, %{properties: []}} = Profile.decode(json(%{id: @id}), "OracleOne")
  end

  test "JSON and profile limits reject ambiguous or malformed identity" do
    nested = Enum.reduce(1..9, 0, fn _, acc -> [acc] end)

    invalid = [
      "{\"id\":\"#{@id}\",\"id\":\"#{@id}\"}",
      json(%{id: @id}) <> "{}",
      json(%{id: nil}),
      json(%{id: 42}),
      json(%{id: "invalid"}),
      json(%{id: @id, properties: [%{name: "textures"}]}),
      json(%{id: @id, properties: [%{name: "textures", value: 42}]}),
      json(%{id: @id, properties: [%{name: String.duplicate("a", 65), value: "a"}]}),
      json(%{id: @id, properties: [%{name: "x", value: "a", signature: false}]}),
      json(%{id: @id, properties: List.duplicate(%{name: "x", value: "a"}, 17)}),
      json(%{id: @id, unknown: nested}),
      json(%{id: @id, unknown: List.duplicate(0, 65)}),
      json(%{id: @id, unknown: String.duplicate("a", 32_768)}),
      json(%{id: @id, unknown: Map.new(1..65, &{to_string(&1), 0})}),
      "{\"id\":\"#{@id}\",\"unknown\":" <> String.duplicate("1", 65) <> "}",
      <<255>>,
      String.duplicate(" ", HTTP.max_body() + 1)
    ]

    for body <- invalid,
        do: assert({:error, :invalid_session_profile} == Profile.decode(body, "OracleOne"))

    assert {:error, :invalid_session_profile} = Profile.decode(json(%{id: @id}), "bad&name")
    assert {:ok, _} = Profile.decode(json(%{id: @id}) <> "\r\n ", "OracleOne")
  end

  test "session query is fixed-origin and failures never return an offline profile" do
    endpoint = "https://sessionserver.mojang.com/session/minecraft/hasJoined"
    assert {:ok, url} = SessionService.url("OracleOne", "-123abc", endpoint)
    assert URI.parse(url).host == "sessionserver.mojang.com"

    assert URI.decode_query(URI.parse(url).query) == %{
             "username" => "OracleOne",
             "serverId" => "-123abc"
           }

    for {name, digest} <- [
          {"bad&name", "abc"},
          {"OracleOne", "ABC"},
          {"OracleOne", "a&ip=evil"},
          {"OracleOne", String.duplicate("a", 41)}
        ] do
      assert {:error, :invalid_session_request} = SessionService.url(name, digest, endpoint)
    end

    assert {:error, :unverified_session} = SessionService.response(204, "", "OracleOne")
    assert {:error, :session_unavailable} = SessionService.response(503, "", "OracleOne")
    assert {:error, :session_unavailable} = SessionService.response(302, "", "OracleOne")
  end

  test "HTTPS validates trusted roots and preserves the bounded exact response" do
    body = json(%{id: @id})

    {url, roots, server} =
      tls_server(fn socket ->
        :ssl.send(socket, [
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
          body
        ])
      end)

    assert {:ok, 200, ^body} = HTTP.get(url, deadline(), roots)
    assert_receive {:tls_request, ^server, request}
    assert request =~ "GET /session HTTP/1.1"
  end

  test "untrusted certificates and wrong hostnames fail without HTTP data" do
    for host <- ["localhost", "wrong.invalid"] do
      {url, roots, server} =
        tls_server(
          fn socket -> :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}") end,
          host
        )

      trust = if host == "localhost", do: :system, else: roots
      assert {:error, :session_unavailable} = HTTP.get(url, deadline(), trust)
      refute_receive {:tls_request, ^server, _}, 20
    end
  end

  test "redirect, HTTP-only and elapsed requests are not followed" do
    {url, roots, _} =
      tls_server(fn socket ->
        :ssl.send(
          socket,
          "HTTP/1.1 302 Found\r\nLocation: https://wrong.invalid/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
      end)

    assert {:ok, 302, ""} = HTTP.get(url, deadline(), roots)
    assert {:error, :session_unavailable} = HTTP.get("http://localhost/", deadline())
    assert {:error, :session_unavailable} = HTTP.get(url, deadline(-1), roots)
  end

  test "declared, chunked and close-delimited oversized bodies and cumulative headers are bounded" do
    huge = String.duplicate("a", HTTP.max_body() + 1)

    responses = [
      ["HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(huge)}\r\n\r\n", huge],
      [
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        Integer.to_string(byte_size(huge), 16),
        "\r\n",
        huge,
        "\r\n0\r\n\r\n"
      ],
      ["HTTP/1.0 200 OK\r\n\r\n", huge],
      [
        "HTTP/1.1 200 OK\r\n",
        Enum.map(1..20, fn i -> "X-#{i}: #{String.duplicate("a", 500)}\r\n" end),
        "Content-Length: 0\r\n\r\n"
      ]
    ]

    for response <- responses do
      {url, roots, server} = tls_server(fn socket -> :ssl.send(socket, response) end)
      assert {:error, :session_unavailable} = HTTP.get(url, deadline(), roots)
      assert_receive {:tls_request, ^server, _}
    end
  end

  test "slow TLS response cannot outlive its deadline" do
    {url, roots, server} = tls_server(fn _ -> Process.sleep(700) end)
    start = System.monotonic_time(:millisecond)
    assert {:error, :session_unavailable} = HTTP.get(url, deadline(200), roots)
    assert_receive {:tls_request, ^server, _}
    assert System.monotonic_time(:millisecond) - start >= 100
    assert System.monotonic_time(:millisecond) - start < 1000
  end

  test "fragmented chunked bodies/trailers and close-delimited bodies decode exactly" do
    for response <- [
          [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "2;fixture=yes\r\n",
            "ab\r\n",
            "1\r\nc\r\n",
            "0\r\nX-Fixture: ok\r\n\r\n"
          ],
          ["HTTP/1.0 200 OK\r\n\r\n", "ab", "c"]
        ] do
      {url, roots, _} =
        tls_server(fn socket ->
          for part <- response, do: :ok = :ssl.send(socket, part)
        end)

      assert {:ok, 200, "abc"} = HTTP.get(url, deadline(), roots)
    end
  end

  test "ambiguous framing, chunk metadata, truncated and encoded responses reject" do
    responses = [
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}",
      "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}",
      "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\naXX0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" <> String.duplicate("0", 8193)
    ]

    for response <- responses do
      {url, roots, server} = tls_server(fn socket -> :ssl.send(socket, response) end)
      assert {:error, :session_unavailable} = HTTP.get(url, deadline(), roots)
      assert_receive {:tls_request, ^server, _}
    end
  end

  test "repeated informational headers and case-insensitive framing tokens are accepted" do
    response =
      "HTTP/1.1 200 OK\r\nX-Minecraft-Request-Id: first\r\nx-minecraft-request-id: second\r\nTransfer-Encoding: Chunked\r\nContent-Encoding: Identity\r\n\r\n2\r\n{}\r\n0\r\n\r\n"

    {url, roots, server} = tls_server(fn socket -> :ssl.send(socket, response) end)
    assert {:ok, 200, "{}"} = HTTP.get(url, deadline(), roots)
    assert_receive {:tls_request, ^server, _}
  end

  test "abrupt worker death closes its passive TLS socket without orphan requests" do
    parent = self()

    {url, roots, server} =
      tls_server(fn socket ->
        receive do
          :check_closed -> send(parent, {:remote_closed, :ssl.recv(socket, 0, 1000)})
        end
      end)

    worker = spawn(fn -> HTTP.get(url, deadline(), roots) end)
    assert_receive {:tls_request, ^server, _}, 2000
    Process.exit(worker, :kill)
    send(server, :check_closed)
    assert_receive {:remote_closed, {:error, :closed}}, 1000
  end
end
