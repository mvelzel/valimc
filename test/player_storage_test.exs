defmodule Valimc.PlayerStorageTest do
  use ExUnit.Case, async: true
  alias Valimc.Player.Storage
  alias Valimc.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  alias Valimc.Storage.{Checkpoint, Log}

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-pose-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  def pose, do: %{x: -17.25, y: 71.5, z: 32.75, yaw: 122.5, pitch: -31.25}
  def state, do: PlayerState.capture(pose(), Inventory.new())

  defp uuid(base) do
    uuid = :crypto.strong_rand_bytes(16)
    Valimc.TestScope.isolate(uuid, world_path: base)
    uuid
  end

  # Send the storage's frames as a group would, and wait until they are durable.
  defp commit(storage, base) do
    route = {:region, :overworld, {0, 0}}
    {frames, storage} = Storage.take(storage, route)
    Log.commit_group(base, route, frames, self())

    Enum.reduce(frames, storage, fn {owner, seq, _}, acc ->
      assert_receive {:storage_durable, ^owner, ^seq}, 5000
      elem(Storage.durable(acc, seq), 0)
    end)
  end

  test "frames carry what changed, volatile records at most once a second; a load folds them",
       %{base: base} do
    uuid = uuid(base)
    assert {:ok, storage, nil} = Storage.read(base, uuid)
    {:ok, storage} = Storage.cut(storage, state())
    assert storage.seq == 1
    storage = commit(storage, base)

    # Moving alone waits for the next second; an inventory change takes it along.
    moved = %{state() | pose: %{pose() | x: -10.25}}
    assert {:ok, ^storage} = Storage.cut(storage, moved)
    stone = ItemStack.new("stone", 3)
    stocked = %{moved | inventory: %Inventory{slots: %{36 => stone}}}
    {:ok, storage} = Storage.cut(storage, stocked)
    assert [{_, 2, frame}] = storage.outbox

    assert MapSet.new(:erlang.binary_to_term(frame), &elem(&1, 1)) ==
             MapSet.new([{:player, :pose}, {:slot, 36}])

    storage = commit(storage, base)
    emptied = %{stocked | inventory: %Inventory{}}
    {:ok, storage} = Storage.cut(storage, emptied, true)
    assert [{_, 3, frame}] = storage.outbox
    assert :erlang.binary_to_term(frame) == [{:del, {:slot, 36}}]
    _storage = commit(storage, base)

    # The file had none of it; the load folds the frames into it.
    refute File.exists?(Storage.path(base, uuid))
    assert {:ok, loaded, ^emptied} = Storage.read(base, uuid)
    assert loaded.seq == 3 and loaded.checkpoint_seq == 3
    assert {:ok, 3} = Checkpoint.seq(Storage.path(base, uuid))
    assert {:ok, ^emptied} = PlayerState.decode(File.read!(Storage.path(base, uuid)), uuid)
  end

  test "a record the file may not hold refuses the frame", %{base: base} do
    {:ok, storage, nil} = Storage.read(base, uuid(base))
    far = %{state() | pose: %{pose() | x: 40_000_000.0}, inventory: %Inventory{selected: 3}}
    assert {:error, :invalid_pose} = Storage.cut(storage, far)
  end

  test "corrupt, oversized, wrong-identity and out-of-bounds files are refused and kept",
       %{base: base} do
    uuid = uuid(base)
    path = Storage.path(base, uuid)
    {:ok, valid} = PlayerState.encode(uuid, state())
    records = Map.put(PlayerState.records(state()), {:player, :uuid}, uuid)
    far = IO.iodata_to_binary(Checkpoint.encode(0, put_in(records[{:player, :pose}].x, 3.0e7)))
    File.mkdir_p!(Path.dirname(path))

    for invalid <- [
          "bad",
          valid <> "extra",
          :binary.copy(<<0>>, PlayerState.max_bytes() + 1),
          binary_part(valid, 0, byte_size(valid) - 32) <> <<0::256>>,
          far
        ] do
      File.write!(path, invalid)
      assert {:error, _} = Storage.read(base, uuid)
      assert File.read!(path) == invalid
    end

    other = uuid(base)
    File.write!(Storage.path(base, other), valid)
    assert {:error, :invalid_player_file} = Storage.read(base, other)
    assert File.read!(Storage.path(base, other)) == valid
  end

  test "an unreadable player path is a scoped error that keeps the path", %{base: base} do
    uuid = uuid(base)
    path = Storage.path(base, uuid)
    File.mkdir_p!(path)
    assert {:error, :eisdir} = Storage.read(base, uuid)
    assert File.dir?(path)
    assert {:ok, _, nil} = Storage.read(base, uuid(base))
  end
end

defmodule Valimc.PlayerStorageTest.Connection do
  # Real logins share the listener and the global world path.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Player.Storage
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog
  import Valimc.PlayerStorageTest, only: [pose: 0]

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
        Registry.lookup(Valimc.PlayerRegistry, uuid) == []
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
             PlayerState.decode(File.read!(Storage.path(base, uuid)), uuid)

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
    path = Storage.path(base, uuid)
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

  test "a failed checkpoint keeps the player playing and its frames durable", %{base: base} do
    name = username()
    {uuid, client} = Client.login(name)
    client = Client.load_world(client)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    path = Storage.path(base, uuid)
    File.mkdir_p!(path)

    send(player.pid, :save_player_now)

    assert capture_log(fn ->
             Valimc.TestWait.until(fn ->
               storage = Valimc.TestConn.state(player.pid).storage

               not storage.requested and storage.checkpointing == nil and
                 storage.seq > storage.checkpoint_seq
             end)
           end) =~ "Player checkpoint failed"

    Client.send_packet(client, :play, "move_player_rot", <<5.0::float-32, 0.0::float-32, 1>>)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    File.rm_rf!(path)
    Client.close(client)
    wait_for_departure(name, uuid)
    assert {:ok, saved} = PlayerState.decode(File.read!(path), uuid)
    assert saved.pose.yaw == 5.0
  end

  test "a group crash disconnects its players; a rejoin loads every durable frame" do
    name = username()
    {uuid, client} = Client.login(name)
    client = Client.load_world(client)
    pid = Enum.find(Valimc.Players.all(), &(&1.name == name)).pid
    stone = ItemStack.new("stone", 5)

    Valimc.TestConn.replace(pid, fn s ->
      %{s | inventory: %{s.inventory | slots: Map.put(s.inventory.slots, 36, stone)}}
    end)

    owner =
      Valimc.TestWait.until(fn ->
        storage = Valimc.TestConn.state(pid).storage

        storage.committed[{:slot, 36}] == stone and storage.outbox == [] and
          storage.in_flight == %{} and :sys.get_state(pid).owner
      end)

    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    {body, _} = Client.await(client, :play, "disconnect")
    assert :binary.match(body, "please reconnect") != :nomatch
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000
    wait_for_departure(name, uuid)
    {^uuid, rejoined} = Client.login(name)
    assert Enum.at(rejoined.inventory.items, 36) == stone
    Client.close(rejoined)
    wait_for_departure(name, uuid)
  end
end
