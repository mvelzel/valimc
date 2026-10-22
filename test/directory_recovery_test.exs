defmodule Valimc.DirectoryRecoveryTest do
  # Kills the global region directory, which restarts every region owner and writer
  # (but not the listener or connections: VMC-077a), and drives real sockets:
  # serial. Until VMC-076d this was the `directory_recovery` vanilla stage.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.World.{Directory, Entities, Region, RegionStorage}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "valimc-directory-recovery-#{System.unique_integer([:positive])}"
      )

    old = Valimc.config(:world_path)
    # Owners left from earlier tests would keep their world path.
    Valimc.TestScope.stop_neighbourhood({0, 0}, spawn: true)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      Valimc.TestScope.stop_players(base)
      Valimc.TestScope.stop_neighbourhood({0, 0}, spawn: true)
      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  defp wait_until(fun, attempts, pause) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(pause)
        {:cont, false}
      end
    end)
  end

  test "directory loss fences owners, writers and routes, restores durable state, replays an unacknowledged committed transfer once and permits reconnect",
       %{base: base} do
    {:ok, owner = {pid, epoch}} = World.owner({0, 0})
    :ok = Valimc.TestBlocks.set({2, 64, 2}, 1)
    :ok = Region.flush(pid)
    {:ok, _handle} = Region.create_item(owner, ItemStack.new("stone", 7), {2.5, 64.5, 3.5})
    [record] = Entities.records(Valimc.TestRegion.section(owner).entities.store)
    {^pid, admission, %{publication: publication}} = Directory.lookup({0, 0})
    [{_, ^pid, ^admission, monitor, _}] = :ets.lookup(Valimc.RegionRoutes, {0, 0})
    name = "DirRecovery"
    uuid = Valimc.Connection.offline_uuid(name)
    source_path = PlayerStore.path(base, uuid)
    refute File.exists?(source_path)

    initial =
      PlayerSnapshot.capture(
        %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0},
        %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
      )

    {:ok, source_bytes} = PlayerSnapshot.encode(uuid, initial)
    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, source_bytes)
    {^uuid, client} = Client.login(name)
    client = Client.load_world(client)
    [player] = Enum.filter(Players.all(), &(&1.name == name))
    writer = Valimc.TestDisk.stripe(base, {0, 0})
    :sys.suspend(writer)

    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id("drop_item")),
      Wire.position({0, 0, 0}),
      <<0, 0>>
    ])

    assert wait_until(
             fn -> Valimc.TestRegion.in_flight?(Valimc.TestRegion.section(owner)) end,
             500,
             5
           )

    {:ok, intent} = PlayerSnapshot.decode(File.read!(source_path), uuid)
    assert intent.transfer_sequence == 1
    [drop] = intent.outbox.records
    assert intent.inventory.slots[36].count == 6
    # Commit on disk while the destination owner cannot acknowledge or publish it.
    :sys.suspend(pid)
    :sys.resume(writer)
    :ok = Valimc.Storage.Log.sync(base, {:region, :overworld, {0, 0}})
    {:ok, %{items: committed, receipts: receipts}} = RegionStorage.read(base, :overworld, {0, 0})
    assert Enum.map(committed, & &1.uuid) |> Enum.sort() == Enum.sort([record.uuid, drop.uuid])
    assert receipts[uuid].sequence == 1
    # The owner adopted and shows the drop at once (D2); only the player's reply waited.
    assert length(Entities.records(Valimc.TestRegion.section(owner).entities.store)) == 2
    assert map_size(World.item_snapshot({0, 0})) == 2
    assert {:ok, ^intent} = PlayerSnapshot.decode(File.read!(source_path), uuid)

    old_directory = Process.whereis(Directory)
    old_listener = Process.whereis(Valimc.Listener)

    old_owners =
      for {_, p, _, _} <- DynamicSupervisor.which_children(Valimc.RegionSupervisor), do: p

    Process.exit(old_directory, :kill)

    assert wait_until(
             fn ->
               directory = Process.whereis(Directory)
               listener = Process.whereis(Valimc.Listener)

               is_pid(directory) and directory != old_directory and listener == old_listener and
                 Enum.all?(old_owners, &(not Process.alive?(&1)))
             end,
             500,
             10
           )

    # The session outlives the world domain's restart.
    assert Process.alive?(player.pid)
    Client.close(client)
    assert :ets.info(publication) == :undefined
    assert {:error, {:retry, :region_unavailable}} = Region.observe_blocks(owner, [])

    case World.existing_owner({0, 0}) do
      {:error, {:retry, :region_unavailable}} ->
        :ok

      {:ok, {recovering, recovered_epoch}} ->
        assert recovering != pid and recovered_epoch != epoch
    end

    {:ok, replacement = {next, next_epoch}} = World.owner({0, 0})
    assert next != pid and next_epoch != epoch
    assert Valimc.TestBlocks.get({2, 64, 2}) == 1
    recovered_records = Entities.records(Valimc.TestRegion.section(replacement).entities.store)
    # Stored records name their kind (VMC-077h).
    expected = Enum.map([record, drop], &Map.put(&1, :kind, :item))
    assert Enum.sort_by(recovered_records, & &1.uuid) == Enum.sort_by(expected, & &1.uuid)
    {:ok, recovered} = Region.find_item(replacement, record.uuid)

    assert {:error, :stale_admission} =
             Directory.publish({0, 0}, admission, %{epoch: epoch, publication: publication})

    send(Directory, {:DOWN, monitor, :process, pid, :killed})
    assert {:ok, ^next} = Directory.admit({0, 0})
    assert {:ok, ^replacement} = World.existing_owner({0, 0})
    # The closed session delivers its outbox and closes its store first.
    Valimc.TestWait.until(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == [] end)
    {^uuid, reconnected} = Client.login(name)
    reconnected = Client.load_world(reconnected)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(PlayerStore.path(base, uuid)), uuid)
    assert saved.outbox == nil
    assert saved.transfer_sequence == 1
    assert saved.inventory.slots[36].count == 6

    assert {:ok, :already_applied} =
             Region.apply_item_transfer(replacement, %{source: uuid, sequence: 1, records: [drop]})

    assert Entities.records(Valimc.TestRegion.section(replacement).entities.store) ==
             recovered_records

    :ok = Region.remove_item(recovered)
    {:ok, dropped} = Region.find_item(replacement, drop.uuid)
    :ok = Region.remove_item(dropped)
    :ok = Valimc.TestBlocks.set({2, 64, 2}, 0)
    Client.close(reconnected)
  end
end
