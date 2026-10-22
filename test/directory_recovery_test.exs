defmodule Valimc.DirectoryRecoveryTest do
  # Kills the global region directory, which restarts every region owner and writer
  # (but not the listener or connections: VMC-077a), and drives real sockets:
  # serial. Until VMC-076d this was the `directory_recovery` vanilla stage.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.World.{Directory, Entities, Region}
  alias Valimc.Protocol.ItemStack
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

  test "directory loss fences owners and routes, restores durable state and permits reconnect",
       %{base: base} do
    {:ok, owner = {pid, epoch}} = Valimc.TestWorld.owner({0, 0})
    :ok = Valimc.TestBlocks.set({2, 64, 2}, 1)
    {:ok, _handle} = Region.create_item(owner, ItemStack.new("stone", 7), {2.5, 64.5, 3.5})
    :ok = Region.flush(pid)
    [record] = Entities.records(Valimc.TestRegion.section(owner).entities.store)
    {^pid, admission, %{publication: publication}} = Valimc.TestWorld.lookup({0, 0})
    [{_, ^pid, ^admission, monitor, _}] = :ets.lookup(Valimc.RegionRoutes, {:overworld, 0, 0})
    name = "DirRecovery"
    uuid = Valimc.Connection.offline_uuid(name)

    initial =
      PlayerState.capture(
        %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0},
        %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
      )

    {:ok, source_bytes} = PlayerState.encode(uuid, initial)
    File.mkdir_p!(Path.dirname(PlayerStore.path(base, uuid)))
    File.write!(PlayerStore.path(base, uuid), source_bytes)
    {^uuid, client} = Client.login(name)
    _client = Client.load_world(client)

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

    assert :ets.info(publication) == :undefined
    assert {:error, {:retry, :region_unavailable}} = Region.observe_blocks(owner, [])
    {:ok, replacement = {next, next_epoch}} = Valimc.TestWorld.owner({0, 0})
    assert next != pid and next_epoch != epoch
    assert Valimc.TestBlocks.get({2, 64, 2}) == 1
    recovered = Entities.records(Valimc.TestRegion.section(replacement).entities.store)
    assert Enum.map(recovered, & &1.uuid) == [record.uuid]

    assert {:error, :stale_admission} =
             Directory.publish({:overworld, 0, 0}, admission, %{
               epoch: epoch,
               publication: publication
             })

    send(Directory, {:DOWN, monitor, :process, pid, :killed})
    assert {:ok, ^next} = Valimc.TestWorld.admit({0, 0})
    assert {:ok, ^replacement} = Valimc.TestWorld.existing_owner({0, 0})
    # The player lost its owner with the world domain; it joins again.
    Valimc.TestWait.until(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, uuid) == [] end)
    {^uuid, reconnected} = Client.login(name)
    reconnected = Client.load_world(reconnected)
    {:ok, saved} = PlayerState.decode(File.read!(PlayerStore.path(base, uuid)), uuid)
    assert saved.inventory.slots[36].count == 7
    {:ok, item} = Region.find_item(replacement, record.uuid)
    :ok = Region.remove_item(item)
    :ok = Valimc.TestBlocks.set({2, 64, 2}, 0)
    Client.close(reconnected)
  end
end
