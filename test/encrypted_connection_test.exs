defmodule Valimc.EncryptedConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Encryption, Wire}
  alias Valimc.{Connection, KeyExchange, LoginKeys, Players}

  setup do
    previous = Valimc.config(:encrypt_login)
    Application.put_env(:valimc, :encrypt_login, true)
    on_exit(fn -> Application.put_env(:valimc, :encrypt_login, previous) end)
    :ok
  end

  defp eventually(fun, n \\ 100) do
    if fun.(),
      do: :ok,
      else:
        (
          assert n > 0
          Process.sleep(5)
          eventually(fun, n - 1)
        )
  end

  defp begin(name) do
    client = Client.begin_login(name)
    {payload, client} = Client.await(client, :login, "hello")
    {"", payload} = Wire.take_string(payload, 20)
    {size, payload} = Wire.take_varint(payload)
    <<encoded::binary-size(^size), payload::binary>> = payload
    {4, <<nonce::binary-size(4), 0>>} = Wire.take_varint(payload)
    pair = LoginKeys.pair()
    assert encoded == pair.encoded
    secret = :crypto.strong_rand_bytes(16)
    {client, pair, nonce, secret}
  end

  defp response(pair, nonce, secret) do
    for value <- [secret, nonce], into: <<>> do
      encrypted =
        :crypto.public_encrypt(:rsa, value, pair.public, rsa_padding: :rsa_pkcs1_padding)

      IO.iodata_to_binary([Wire.varint(byte_size(encrypted)), encrypted])
    end
  end

  defp owner(name) do
    Enum.find_value(DynamicSupervisor.which_children(Valimc.ConnectionSupervisor), fn {_, pid, _,
                                                                                       _} ->
      case :sys.get_state(pid) do
        %{login_name: ^name} -> pid
        _ -> nil
      end
    end)
  end

  defp assert_no_lease(pid, name) do
    assert Players.get(pid) == :error
    assert Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)) == []
  end

  test "fragmented plaintext key response, encrypted configuration/chunks/commands and independent peer" do
    name = "EncryptedOne"
    {client, pair, nonce, secret} = begin(name)
    pid = owner(name)
    assert_no_lease(pid, name)
    body = response(pair, nonce, secret)

    keyframe =
      Wire.frame(Data.id(:login, :serverbound, "key"), body, nil) |> IO.iodata_to_binary()

    for <<byte <- keyframe>>, do: :ok = :gen_tcp.send(client.socket, <<byte>>)
    {:ok, cipher} = Encryption.new(secret)
    {uuid, client} = Client.login_session(Map.put(client, :cipher, cipher), name)
    client = Client.load_world(client)
    assert uuid == Connection.offline_uuid(name)
    assert :sys.get_state(pid).cipher.owner == pid
    client = Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {body, client} = Client.await(client, :play, "system_chat")
    assert byte_size(body) > 0
    {peer, pair, nonce, secret} = begin("EncryptedTwo")
    peer = Client.send_packet(peer, :login, "key", response(pair, nonce, secret))
    {:ok, cipher} = Encryption.new(secret)
    {_uuid, peer} = Client.login_session(Map.put(peer, :cipher, cipher), "EncryptedTwo")
    Client.close(peer)
    Client.close(client)
  end

  test "plaintext key frame and encrypted compressed acknowledgment coalesce; encrypted rejection works" do
    name = "EncryptedTail"
    {client, pair, nonce, secret} = begin(name)
    {:ok, cipher} = Encryption.new(secret)
    key = Wire.frame(Data.id(:login, :serverbound, "key"), response(pair, nonce, secret), nil)

    ack =
      Wire.frame(
        Data.id(:login, :serverbound, "login_acknowledged"),
        <<>>,
        Valimc.config(:compression_threshold)
      )
      |> IO.iodata_to_binary()

    {:ok, encrypted} = Encryption.encrypt(cipher, ack)
    :ok = :gen_tcp.send(client.socket, [key, encrypted])
    client = client |> Map.put(:cipher, cipher) |> Map.put(:login_ack_sent, true)
    {_uuid, client} = Client.login_session(client, name)
    client = Client.load_world(client)
    client = Client.send_raw(client, Wire.frame(2_000_000, <<>>, client.threshold))
    {body, _} = Client.await(client, :play, "disconnect")
    assert byte_size(body) > 0
    Client.close(client)
  end

  test "wrong challenge and unsolicited key reject before acquiring a lease" do
    name = "BadEncryption"
    {client, pair, nonce, secret} = begin(name)
    pid = owner(name)
    <<first, rest::binary>> = nonce
    bad = response(pair, <<Bitwise.bxor(first, 1), rest::binary>>, secret)
    client = Client.send_packet(client, :login, "key", bad)
    {_body, _} = Client.await(client, :login, "login_disconnect")
    eventually(fn -> not Process.alive?(pid) end)
    assert_no_lease(pid, name)
    Client.close(client)
    client = Client.connect()

    client =
      Client.send_packet(client, :handshake, "intention", [
        Wire.varint(777),
        Wire.string("localhost"),
        <<25565::16>>,
        <<2>>
      ])

    client = Client.send_packet(client, :login, "key", bad)
    {_body, _} = Client.await(client, :login, "login_disconnect")
    Client.close(client)

    {client, pair, nonce, secret} = begin("CryptoReplay")
    pid = owner("CryptoReplay")
    body = response(pair, nonce, secret)
    client = Client.send_packet(client, :login, "key", body)
    {:ok, cipher} = Encryption.new(secret)
    client = Map.put(client, :cipher, cipher)
    {compression, client} = Client.await(client, :login, "login_compression")
    {threshold, <<>>} = Wire.take_varint(compression)
    client = %{client | threshold: threshold}
    {_body, client} = Client.await(client, :login, "login_finished")
    client = Client.send_packet(client, :login, "key", body)
    {_body, _} = Client.await(client, :login, "login_disconnect")
    eventually(fn -> not Process.alive?(pid) end)

    eventually(fn ->
      Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid("CryptoReplay")) == []
    end)

    Client.close(client)
  end

  test "bounded pool saturation rejects an extra login, then releases capacity" do
    pair = LoginKeys.pair()
    nonce = Encryption.challenge()
    body = response(pair, nonce, <<0::128>>)
    limit = :sys.get_state(KeyExchange).limit

    jobs =
      for _ <- 1..limit do
        assert {:ok, job} = KeyExchange.start(self(), make_ref(), pair, nonce, body)
        job
      end

    try do
      name = "CryptoBusy"
      {client, pair, nonce, secret} = begin(name)
      pid = owner(name)
      client = Client.send_packet(client, :login, "key", response(pair, nonce, secret))
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      assert_no_lease(pid, name)
      Client.close(client)
    after
      for job <- jobs do
        Process.demonitor(job.monitor, [:flush])
        KeyExchange.cancel(job)
      end
    end

    eventually(fn -> map_size(:sys.get_state(KeyExchange).jobs) == 0 end)
  end

  test "pending deadline, late valid results and stale messages cannot grant a lease" do
    for {name, late} <- [{"CryptoDeadline", false}, {"CryptoLate", true}] do
      {client, pair, nonce, secret} = begin(name)
      pid = owner(name)
      body = response(pair, nonce, secret)

      :sys.replace_state(pid, fn state ->
        token = make_ref()
        {:ok, job} = KeyExchange.start(self(), token, pair, nonce, body)
        deadline = System.monotonic_time(:millisecond) + if(late, do: -1, else: 100)
        timer = Process.send_after(self(), {:key_deadline, token}, if(late, do: 5000, else: 100))
        if late, do: KeyExchange.activate(job)

        %{
          state
          | step: :key_job,
            key_pair: nil,
            key_challenge: nil,
            key_job: Map.merge(job, %{deadline: deadline, timer: timer})
        }
      end)

      send(pid, {:key_deadline, make_ref()})
      send(pid, {:key_verified, self(), make_ref(), {:ok, secret}})
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      assert_no_lease(pid, name)
      Client.close(client)
    end

    eventually(fn -> map_size(:sys.get_state(KeyExchange).jobs) == 0 end)
  end

  test "abrupt admission-owner death reclaims dormant workers without relying on terminate" do
    parent = self()
    pair = LoginKeys.pair()
    nonce = Encryption.challenge()
    body = response(pair, nonce, <<0::128>>)

    caller =
      spawn(fn ->
        {:ok, job} = KeyExchange.start(self(), make_ref(), pair, nonce, body)
        send(parent, {:dormant_worker, job.pid})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:dormant_worker, worker}
    ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
    eventually(fn -> map_size(:sys.get_state(KeyExchange).jobs) == 0 end)
  end

  test "stalled admission is bounded and existing encrypted gameplay remains responsive" do
    name = "CryptoLive"
    {live, pair, nonce, secret} = begin(name)
    live = Client.send_packet(live, :login, "key", response(pair, nonce, secret))
    {:ok, cipher} = Encryption.new(secret)
    {_uuid, live} = Client.login_session(Map.put(live, :cipher, cipher), name)
    live = Client.load_world(live)
    {client, pair, nonce, secret} = begin("AdmissionWait")
    pid = owner("AdmissionWait")
    :sys.suspend(KeyExchange)

    try do
      client = Client.send_packet(client, :login, "key", response(pair, nonce, secret))
      live = Client.send_packet(live, :play, "chat_command", Wire.string("stats"))
      {body, _} = Client.await(live, :play, "system_chat")
      assert byte_size(body) > 0
      {_body, _} = Client.await(client, :login, "login_disconnect")
      eventually(fn -> not Process.alive?(pid) end)
      assert_no_lease(pid, "AdmissionWait")
    after
      :sys.resume(KeyExchange)
      Client.close(client)
      Client.close(live)
    end

    eventually(fn -> map_size(:sys.get_state(KeyExchange).jobs) == 0 end)
  end

  test "key infrastructure loss closes dependent sessions and recreates a usable service" do
    name = "KeyOwnerLoss"
    {client, pair, nonce, secret} = begin(name)
    pid = owner(name)
    client = Client.send_packet(client, :login, "key", response(pair, nonce, secret))
    {:ok, cipher} = Encryption.new(secret)
    {_uuid, client} = Client.login_session(Map.put(client, :cipher, cipher), name)
    old = Process.whereis(LoginKeys)
    listener = Process.whereis(Valimc.Listener)
    monitor = Process.monitor(pid)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000

    eventually(
      fn ->
        Process.whereis(LoginKeys) not in [nil, old] and
          Process.whereis(Valimc.Listener) not in [nil, listener]
      end,
      400
    )

    Client.close(client)
    {peer, pair, nonce, secret} = begin("AfterKeyLoss")
    peer = Client.send_packet(peer, :login, "key", response(pair, nonce, secret))
    {:ok, cipher} = Encryption.new(secret)
    {_uuid, peer} = Client.login_session(Map.put(peer, :cipher, cipher), "AfterKeyLoss")
    Client.close(peer)
  end
end
