defmodule Valimc.PlayerStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerStore, as: Store
  alias Valimc.Inventory
  alias Valimc.Player.State, as: PlayerState
  import ExUnit.CaptureLog

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-pose-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  def snapshot, do: PlayerState.capture(pose(), Inventory.new())
  def pose, do: %{x: -17.25, y: 71.5, z: 32.75, yaw: 122.5, pitch: -31.25}

  # A fresh identity whose store writes under `base`.
  defp uuid(base) do
    uuid = :crypto.strong_rand_bytes(16)
    Valimc.TestScope.isolate(uuid, world_path: base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: Valimc.TestScope.kill(pid)
    end)

    uuid
  end

  test "lease fences reconnects while a writer is stalled; unrelated writers run", %{base: base} do
    uuid = uuid(base)
    {:ok, writer, nil, writer_fence} = Store.open(uuid)
    :sys.suspend(writer)

    try do
      assert {:error, :session_closing} = Store.open(uuid)
      {:ok, healthy, nil, healthy_fence} = Store.open(uuid(base))
      assert :ok = Store.close(healthy, healthy_fence, snapshot())
    after
      :sys.resume(writer)
    end

    ref = Process.monitor(writer)
    assert :ok = Store.close(writer, writer_fence, snapshot())
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    {:ok, replacement, restored, replacement_fence} = Store.open(uuid)
    assert restored.pose == pose()
    assert :ok = Store.close(replacement, replacement_fence, restored)
  end

  test "corrupt, oversized, wrong-identity and out-of-bounds files are preserved", %{base: base} do
    uuid = uuid(base)
    {:ok, writer, nil, writer_fence} = Store.open(uuid)
    ref = Process.monitor(writer)
    assert :ok = Store.close(writer, writer_fence, snapshot())
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    path = Store.path(base, uuid)
    valid = File.read!(path)
    payload = binary_part(valid, 0, byte_size(valid) - 32)
    <<header::binary-size(24), _x::binary-size(8), rest::binary>> = payload
    <<magic::binary-size(7), _version, fields::binary>> = payload
    future_version = magic <> <<4>> <> fields
    out_of_bounds = header <> <<30_000_000.0::float-64>> <> rest
    nan = header <> <<0x7FF8000000000000::64>> <> rest

    for invalid <- [
          "bad",
          valid <> "extra",
          :binary.copy(<<0>>, PlayerState.max_bytes() + 1),
          payload <> <<0::256>>,
          future_version <> :crypto.hash(:sha256, future_version),
          out_of_bounds <> :crypto.hash(:sha256, out_of_bounds),
          nan <> :crypto.hash(:sha256, nan)
        ] do
      File.write!(path, invalid)
      assert {:error, :invalid_player_file} = Store.open(uuid)
      assert File.read!(path) == invalid
      Valimc.TestWait.until(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == [] end)
    end

    other = uuid(base)
    File.write!(Store.path(base, other), valid)
    assert {:error, :invalid_player_file} = Store.open(other)
    assert File.read!(Store.path(base, other)) == valid
  end

  test "unreadable player paths return a scoped error without replacing the path", %{base: base} do
    uuid = uuid(base)
    path = Store.path(base, uuid)
    File.mkdir_p!(path)
    assert {:error, :eisdir} = Store.open(uuid)
    assert File.dir?(path)
    {:ok, healthy, nil, healthy_fence} = Store.open(uuid(base))
    assert :ok = Store.close(healthy, healthy_fence, snapshot())
  end

  test "periodic save acknowledges a complete checkpoint and write failure stays isolated", %{
    base: base
  } do
    uuid = uuid(base)
    {:ok, writer, nil, writer_fence} = Store.open(uuid)
    ref = make_ref()
    Store.checkpoint(writer, writer_fence, snapshot(), ref)
    assert_receive {:player_saved, ^ref, :ok}
    assert File.exists?(Store.path(base, uuid))

    # Turn the directory into a file to force a real filesystem error.
    File.rm_rf!(base)
    File.write!(base, "blocked")
    ref = make_ref()

    assert capture_log(fn ->
             Store.checkpoint(writer, writer_fence, snapshot(), ref)
             assert_receive {:player_saved, ^ref, {:error, _}}
           end) =~ "Player state save failed"

    File.rm!(base)
    assert :ok = Store.close(writer, writer_fence, snapshot())
  end
end

defmodule Valimc.PlayerStoreTest.Connection do
  # Real logins share the listener and the global world path.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.PlayerStore, as: Store
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Wire}
  import ExUnit.CaptureLog
  import Valimc.PlayerStoreTest, only: [pose: 0]

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-pose-#{System.unique_integer([:positive])}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  defp username, do: "Pose" <> Integer.to_string(System.unique_integer([:positive]))

  defp wait_for_departure(name, uuid) do
    Valimc.TestWait.until(fn ->
      not Enum.any?(:ets.tab2list(Valimc.Players), fn {_, player} -> player.name == name end) and
        Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == []
    end)
  end

  test "reconnect and supervised shutdown restore pose; new identities use spawn", %{base: base} do
    name = username()
    {uuid, client} = Client.login(name)
    client = Client.load_world(client)
    assert client.pose == %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    client = Client.teleport(client, player.pid, pose())
    ref = Process.monitor(player.pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    wait_for_departure(name, uuid)

    assert {:ok, %{effects: %{}}} =
             PlayerState.decode(File.read!(Store.path(base, uuid)), uuid)

    {^uuid, second} = Client.login(name)
    assert second.pose == pose()
    second = Client.load_world(second)
    next = %{pose() | x: -19.5, yaw: -80.0}
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    Client.teleport(second, player.pid, next)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)
    Client.close(second)
    wait_for_departure(name, uuid)

    {^uuid, third} = Client.login(name)
    assert third.pose == next
    Client.close(third)
    wait_for_departure(name, uuid)

    other_name = username()
    {other_uuid, other} = Client.login(other_name)
    assert other.pose.x == 0.5
    Client.close(other)
    wait_for_departure(other_name, other_uuid)
  end

  test "bad save rejects only that login; healthy listener and identity still work", %{base: base} do
    name = username()
    uuid = Valimc.Connection.offline_uuid(name)
    path = Store.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "broken")
    bad = Client.connect()

    assert capture_log(fn ->
             Client.send_packet(bad, :handshake, "intention", [
               Wire.varint(777),
               Wire.string("localhost"),
               <<25565::16, 2>>
             ])

             Client.send_packet(bad, :login, "hello", [Wire.string(name), <<0::128>>])
             {id, body, _} = Client.read(bad)
             assert id == Data.id(:login, :clientbound, "login_disconnect")
             assert :binary.match(body, "Player save unavailable") != :nomatch
           end) =~ "Player state load failed"

    Client.close(bad)
    assert File.read!(path) == "broken"
    healthy_name = username()
    {healthy_uuid, healthy} = Client.login(healthy_name)
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(healthy)
    Client.close(healthy)
    wait_for_departure(healthy_name, healthy_uuid)
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "a stalled writer accepts one checkpoint while another session responds" do
    name = username()
    {uuid, client} = Client.login(name)
    client = Client.load_world(client)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    [{writer, _}] = Registry.lookup(Valimc.PlayerStoreRegistry, uuid)
    :sys.suspend(writer)

    try do
      for _ <- 1..3, do: send(player.pid, :save_player)
      state = :sys.get_state(player.pid)
      assert is_reference(state.save_ref)
      assert {:message_queue_len, 1} = Process.info(writer, :message_queue_len)
      healthy_name = username()
      {healthy_uuid, healthy} = Client.login(healthy_name)
      Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
      {_, _} = Client.await_stats(healthy)
      Client.close(healthy)
      wait_for_departure(healthy_name, healthy_uuid)
    after
      :sys.resume(writer)
      Client.close(client)
    end

    wait_for_departure(name, uuid)
  end

  test "a real write failure disconnects only its owner and preserves peers", %{base: base} do
    name = username()
    {uuid, bad} = Client.login(name)
    bad = Client.load_world(bad)
    healthy_name = username()
    {healthy_uuid, healthy} = Client.login(healthy_name)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    ref = Process.monitor(player.pid)
    File.mkdir_p!(Store.path(base, uuid))

    assert capture_log(fn ->
             send(player.pid, :save_player)
             {body, _} = Client.await(bad, :play, "disconnect")
             assert :binary.match(body, "Player save failed") != :nomatch
             assert_receive {:DOWN, ^ref, :process, _, :normal}
           end) =~ "Player state save failed"

    Client.close(bad)
    wait_for_departure(name, uuid)
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(healthy)
    Client.close(healthy)
    wait_for_departure(healthy_name, healthy_uuid)
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end
end
