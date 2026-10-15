defmodule Valimc.PlayerStoreTest do
  use ExUnit.Case, async: false
  alias Valimc.PlayerStore, as: Store
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Wire}
  import ExUnit.CaptureLog

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-pose-#{System.unique_integer([:positive])}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  defp username, do: "Pose" <> Integer.to_string(System.unique_integer([:positive]))
  defp snapshot, do: PlayerSnapshot.capture(pose(), Inventory.new())
  defp uuid, do: :crypto.strong_rand_bytes(16)
  defp pose, do: %{x: -17.25, y: 71.5, z: 32.75, yaw: 122.5, pitch: -31.25}

  defp wait_for_departure(name, uuid, retries \\ 100) do
    if Enum.any?(:ets.tab2list(Valimc.Players), fn {_, player} -> player.name == name end) or
         Registry.lookup(Valimc.PlayerStoreRegistry, uuid) != [] do
      assert retries > 0
      Process.sleep(10)
      wait_for_departure(name, uuid, retries - 1)
    end
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
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    wait_for_departure(name, uuid)
    assert byte_size(File.read!(Store.path(base, uuid))) == 190

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

  test "lease fences reconnects while a writer is stalled; unrelated writers run" do
    uuid = uuid()
    {:ok, writer, nil, writer_fence} = Store.open(uuid)
    :sys.suspend(writer)

    try do
      assert {:error, :session_closing} = Store.open(uuid)
      {:ok, healthy, nil, healthy_fence} = Store.open(uuid())
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
    uuid = uuid()
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
          :binary.copy(<<0>>, PlayerSnapshot.max_bytes() + 1),
          payload <> <<0::256>>,
          future_version <> :crypto.hash(:sha256, future_version),
          out_of_bounds <> :crypto.hash(:sha256, out_of_bounds),
          nan <> :crypto.hash(:sha256, nan)
        ] do
      File.write!(path, invalid)
      assert {:error, :invalid_player_file} = Store.open(uuid)
      assert File.read!(path) == invalid
      wait_for_departure("", uuid)
    end

    other = uuid()
    File.write!(Store.path(base, other), valid)
    assert {:error, :invalid_player_file} = Store.open(other)
    assert File.read!(Store.path(base, other)) == valid
  end

  test "unreadable player paths return a scoped error without replacing the path", %{base: base} do
    uuid = uuid()
    path = Store.path(base, uuid)
    File.mkdir_p!(path)
    assert {:error, :eisdir} = Store.open(uuid)
    assert File.dir?(path)
    {:ok, healthy, nil, healthy_fence} = Store.open(uuid())
    assert :ok = Store.close(healthy, healthy_fence, snapshot())
  end

  test "periodic save acknowledges a complete checkpoint and write failure stays isolated", %{
    base: base
  } do
    uuid = uuid()
    {:ok, writer, nil, writer_fence} = Store.open(uuid)
    ref = make_ref()
    Store.checkpoint(writer, writer_fence, snapshot(), ref)
    assert_receive {:player_saved, ^ref, :ok}, 1000
    assert byte_size(File.read!(Store.path(base, uuid))) == 139

    # Turn the directory into a file to force a real filesystem error.
    File.rm_rf!(base)
    File.write!(base, "blocked")
    ref = make_ref()

    assert capture_log(fn ->
             Store.checkpoint(writer, writer_fence, snapshot(), ref)
             assert_receive {:player_saved, ^ref, {:error, _}}, 1000
           end) =~ "Player state save failed"

    File.rm!(base)
    assert :ok = Store.close(writer, writer_fence, snapshot())
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
    {_, _} = Client.await(healthy, :play, "system_chat")
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
      {_, _} = Client.await(healthy, :play, "system_chat")
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
             assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
           end) =~ "Player state save failed"

    Client.close(bad)
    wait_for_departure(name, uuid)
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await(healthy, :play, "system_chat")
    Client.close(healthy)
    wait_for_departure(healthy_name, healthy_uuid)
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "a rejected later frame preserves earlier validated movement in the same TCP batch" do
    name = username()
    {uuid, client} = Client.login(name)
    client = Client.load_world(client)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    ref = Process.monitor(player.pid)
    body = <<-4.25::float-64, 64.0::float-64, -2.5::float-64, 1>>
    bad = <<30_000_000.0::float-64, 64.0::float-64, 0.0::float-64, 1>>
    id = Data.id(:play, :serverbound, "move_player_pos")

    Client.send_raw(client, [
      Wire.frame(id, body, client.threshold),
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_rot"),
        <<83.0::float-32, 0.0::float-32, 1>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold),
      Wire.frame(id, bad, client.threshold)
    ])

    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    Client.close(client)
    wait_for_departure(name, uuid)
    {^uuid, next} = Client.login(name)
    assert next.pose.x == -4.25 and next.pose.z == -2.5
    assert next.pose.yaw == 83.0
    Client.close(next)
    wait_for_departure(name, uuid)
  end

  test "a failed phase-transition batch saves its earlier committed play rotation", %{base: base} do
    for bad <- [:rejected_frame, :invalid_payload] do
      name = username()
      {uuid, client} = Client.configure(name)
      [{pid, _}] = Enum.filter(:ets.tab2list(Valimc.Players), fn {_, p} -> p.name == name end)
      state = :sys.get_state(pid)
      assert state.phase == :configuration
      assert state.step == :finish
      ref = Process.monitor(pid)
      target = %{pose() | x: 0.5, y: 64.0, z: 0.5}
      confirm = <<1, 0.5::float-64, 64.0::float-64, 0.5::float-64, 0.0::float-32, 0.0::float-32>>

      movement =
        <<target.x::float-64, target.y::float-64, target.z::float-64, target.yaw::float-32,
          target.pitch::float-32, 1>>

      broken =
        if bad == :rejected_frame,
          do: <<128, 128, 128, 128, 128, 128>>,
          else:
            Wire.frame(
              Data.id(:play, :serverbound, "move_player_pos_rot"),
              <<>>,
              client.threshold
            )

      batch =
        IO.iodata_to_binary([
          Wire.frame(
            Data.id(:configuration, :serverbound, "finish_configuration"),
            <<>>,
            client.threshold
          ),
          Wire.frame(
            Data.id(:play, :serverbound, "accept_teleportation"),
            confirm,
            client.threshold
          ),
          Wire.frame(
            Data.id(:play, :serverbound, "move_player_pos_rot"),
            movement,
            client.threshold
          ),
          broken
        ])

      # Control the exact callback boundary; arbitrary TCP segmentation must not hide the bug.
      send(pid, {:tcp, state.socket, batch})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      Client.close(client)
      wait_for_departure(name, uuid)
      assert File.exists?(Store.path(base, uuid))
      {^uuid, next} = Client.login(name)
      assert next.pose == target
      Client.close(next)
      wait_for_departure(name, uuid)
    end
  end

  test "a rejected configuration leaves an existing player save untouched", %{base: base} do
    name = username()
    uuid = Valimc.Connection.offline_uuid(name)
    {:ok, writer, nil, writer_fence} = Store.open(uuid)
    ref = Process.monitor(writer)
    assert :ok = Store.close(writer, writer_fence, snapshot())
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    path = Store.path(base, uuid)
    saved = File.read!(path)
    {^uuid, client} = Client.configure(name)
    [{pid, _}] = Enum.filter(:ets.tab2list(Valimc.Players), fn {_, p} -> p.name == name end)
    ref = Process.monitor(pid)
    Client.send_packet(client, :configuration, "finish_configuration", <<1>>)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    Client.close(client)
    wait_for_departure(name, uuid)
    assert File.read!(path) == saved
    {^uuid, next} = Client.login(name)
    assert next.pose == pose()
    Client.close(next)
    wait_for_departure(name, uuid)
  end
end
