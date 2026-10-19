defmodule Valimc.ControlledSessionService do
  def lookup(name, digest, deadline) do
    send(
      Application.fetch_env!(:valimc, :auth_test_owner),
      {:verify_session, self(), name, digest, deadline}
    )

    receive do
      {:auth_result, result} -> result
    after
      5000 -> {:error, :session_unavailable}
    end
  end
end

defmodule Valimc.OnlineConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Encryption, Wire}
  alias Valimc.{Connection, LoginKeys, Players}
  alias Valimc.Auth.SessionJobs

  setup do
    previous =
      for key <- [:online_mode, :encrypt_login, :session_service, :auth_test_owner],
          into: %{},
          do: {key, Application.get_env(:valimc, key)}

    Application.put_env(:valimc, :online_mode, true)
    Application.put_env(:valimc, :encrypt_login, false)
    Application.put_env(:valimc, :session_service, Valimc.ControlledSessionService)
    Application.put_env(:valimc, :auth_test_owner, self())

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:valimc, key),
          else: Application.put_env(:valimc, key, value)
      end
    end)

    :ok
  end

  defp eventually(fun, n \\ 200) do
    if fun.(),
      do: :ok,
      else:
        (
          assert n > 0
          Process.sleep(5)
          eventually(fun, n - 1)
        )
  end

  defp owner(name), do: Client.connection(name)

  defp profile(name) do
    %{
      name: name,
      uuid: :crypto.hash(:md5, "synthetic-online:" <> name),
      properties: [
        %{name: "textures", value: "synthetic-value+/=", signature: "synthetic-signature+/="},
        %{name: "other", value: "unsigned λ", signature: nil}
      ]
    }
  end

  defp key(name, tail \\ false) do
    client = Client.begin_login(name)
    {body, client} = Client.await(client, :login, "hello")
    {"", body} = Wire.take_string(body)
    {size, body} = Wire.take_varint(body)
    <<encoded::binary-size(^size), body::binary>> = body
    {4, <<nonce::binary-size(4), 1>>} = Wire.take_varint(body)
    pair = LoginKeys.pair()
    assert encoded == pair.encoded
    pid = owner(name)
    secret = :crypto.strong_rand_bytes(16)

    response =
      for bytes <- [secret, nonce], into: <<>> do
        encrypted =
          :crypto.public_encrypt(:rsa, bytes, pair.public, rsa_padding: :rsa_pkcs1_padding)

        IO.iodata_to_binary([Wire.varint(byte_size(encrypted)), encrypted])
      end

    {:ok, cipher} = Encryption.new(secret)
    frame = Wire.frame(Data.id(:login, :serverbound, "key"), response, nil)

    if tail do
      ack =
        Wire.frame(
          Data.id(:login, :serverbound, "login_acknowledged"),
          <<>>,
          Valimc.config(:compression_threshold)
        )
        |> IO.iodata_to_binary()

      {:ok, bytes} = Encryption.encrypt(cipher, ack)
      :ok = :gen_tcp.send(client.socket, [frame, bytes])
    else
      :ok = :gen_tcp.send(client.socket, frame)
    end

    client = client |> Map.put(:cipher, cipher) |> Map.put(:login_ack_sent, tail)
    {client, pid, Encryption.server_hash(secret, encoded)}
  end

  defp no_lease(pid, name) do
    assert :ets.lookup(Players, pid) == []

    for uuid <- [Connection.offline_uuid(name), profile(name).uuid],
        do: assert(Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == [])
  end

  defp verified(name) do
    {client, pid, digest} = key(name)
    assert_receive {:verify_session, worker, ^name, ^digest, _}, 1000
    no_lease(pid, name)
    send(worker, {:auth_result, {:ok, profile(name)}})
    {uuid, client} = Client.login_session(client, name)
    assert uuid == profile(name).uuid
    assert client.properties == profile(name).properties
    {Client.load_world(client), pid}
  end

  test "online mode enforces encryption and authenticated UUID/properties before admission" do
    name = "VerifiedOne"
    {client, pid} = verified(name)
    assert {:ok, player} = Players.get(pid)
    assert player.uuid == profile(name).uuid
    assert player.uuid != Connection.offline_uuid(name)
    assert player.properties == profile(name).properties
    state = Valimc.TestConn.state(pid)
    assert state.cipher.owner == pid and state.auth_job == nil
    assert state.key_public == nil and state.key_pair == nil and state.key_challenge == nil
    client = Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await(client, :play, "system_chat")
    Client.close(client)
    eventually(fn -> not Process.alive?(pid) end)
    eventually(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, profile(name).uuid) == [] end)
    {client, _} = verified(name)
    Client.close(client)
  end

  test "coalesced encrypted tail waits for verification; stale results cannot admit" do
    name = "VerifiedTail"
    {client, pid, digest} = key(name, true)
    assert_receive {:verify_session, worker, ^name, ^digest, _}, 1000
    no_lease(pid, name)
    send(pid, {:session_verified, self(), make_ref(), {:ok, profile(name)}})
    send(pid, {:session_deadline, make_ref()})
    assert Valimc.TestConn.state(pid).step == :auth_job
    no_lease(pid, name)
    send(worker, {:auth_result, {:ok, profile(name)}})
    {uuid, client} = Client.login_session(client, name)
    assert uuid == profile(name).uuid
    Client.close(Client.load_world(client))
  end

  test "unverified, unavailable and malformed profiles reject without offline fallback" do
    for {name, result} <- [
          {"InvalidSession", {:error, :unverified_session}},
          {"AuthDown", {:error, :session_unavailable}},
          {"WrongProfile", {:ok, profile("DifferentName")}},
          {"ShortUUID", {:ok, %{profile("ShortUUID") | uuid: <<1>>}}},
          {"HugeProperties",
           {:ok,
            %{
              profile("HugeProperties")
              | properties: List.duplicate(hd(profile("HugeProperties").properties), 17)
            }}}
        ] do
      {client, pid, digest} = key(name)
      assert_receive {:verify_session, worker, ^name, ^digest, _}, 1000
      no_lease(pid, name)
      send(worker, {:auth_result, result})
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      no_lease(pid, name)
      Client.close(client)
    end
  end

  test "authentication saturation rejects a new peer while existing encrypted play responds" do
    {live, _} = verified("AuthLive")
    limit = :sys.get_state(SessionJobs).limit

    jobs =
      for _ <- 1..limit do
        {:ok, job} = SessionJobs.start(self(), make_ref(), "Dormant", "abc")
        job
      end

    try do
      {client, pid, _} = key("AuthBusy")
      live = Client.send_packet(live, :play, "chat_command", Wire.string("stats"))
      {_body, _} = Client.await(live, :play, "system_chat")
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      no_lease(pid, "AuthBusy")
      Client.close(client)
    after
      for job <- jobs do
        Process.demonitor(job.monitor, [:flush])
        SessionJobs.cancel(job)
      end

      Client.close(live)
    end

    eventually(fn -> map_size(:sys.get_state(SessionJobs).jobs) == 0 end)
  end

  test "absolute deadlines reject late valid results and expire stalled verification" do
    for {name, late} <- [{"AuthDeadline", false}, {"AuthLate", true}] do
      {client, pid, digest} = key(name)
      assert_receive {:verify_session, worker, ^name, ^digest, _}, 1000

      :sys.replace_state(pid, fn state ->
        job = state.auth_job
        Process.cancel_timer(job.timer)
        ms = if late, do: -1, else: 100

        timer =
          Process.send_after(self(), {:session_deadline, job.token}, if(late, do: 5000, else: ms))

        %{
          state
          | auth_job: %{job | deadline: System.monotonic_time(:millisecond) + ms, timer: timer}
        }
      end)

      if late, do: send(worker, {:auth_result, {:ok, profile(name)}})
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      no_lease(pid, name)
      Client.close(client)
    end

    eventually(fn -> map_size(:sys.get_state(SessionJobs).jobs) == 0 end)
  end

  test "abrupt connection loss cancels its authentication worker and reclaims capacity" do
    {client, pid, digest} = key("AuthOwnerGone")
    assert_receive {:verify_session, worker, "AuthOwnerGone", ^digest, _}, 1000
    ref = Process.monitor(worker)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
    no_lease(pid, "AuthOwnerGone")
    Client.close(client)
    eventually(fn -> map_size(:sys.get_state(SessionJobs).jobs) == 0 end)
  end

  test "worker failure rejects its pending encrypted login" do
    {client, pid, digest} = key("AuthWorkerGone")
    assert_receive {:verify_session, worker, "AuthWorkerGone", ^digest, _}, 1000
    Process.exit(worker, :kill)
    {_body, _} = Client.await(client, :login, "login_disconnect")
    eventually(fn -> not Process.alive?(pid) end)
    no_lease(pid, "AuthWorkerGone")
    Client.close(client)
  end

  test "stalled auth admission is bounded without blocking an admitted player" do
    {live, _} = verified("SessionLive")
    :sys.suspend(SessionJobs)

    try do
      {client, pid, _} = key("SessionAdmission")
      live = Client.send_packet(live, :play, "chat_command", Wire.string("stats"))
      {_body, _} = Client.await(live, :play, "system_chat")
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      no_lease(pid, "SessionAdmission")
      Client.close(client)
    after
      :sys.resume(SessionJobs)
      Client.close(live)
    end

    eventually(fn -> map_size(:sys.get_state(SessionJobs).jobs) == 0 end)
  end
end
