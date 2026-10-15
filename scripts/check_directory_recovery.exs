# Run in a separate BEAM with VALIMC_PORT=0 and a fresh VALIMC_WORLD.
Code.require_file("../test/support/client.ex", __DIR__)
alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
alias Valimc.World.{Directory, Items, Region, Store}
alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
alias Valimc.TestClient, as: Client
true = is_binary(Valimc.config(:world_path))
{:ok, owner = {pid, epoch}} = World.owner({0, 0})
:ok = World.set_block({2, 64, 2}, 1)
:ok = Region.flush(pid)
{:ok, handle} = Region.create_item(owner, ItemStack.new("stone", 7), {2.5, 64.5, 3.5})
[record] = Items.records(:sys.get_state(pid).resource.items)
{^pid, admission, %{items: publication}} = Directory.lookup({0, 0})
[{_, ^pid, ^admission, monitor, _}] = :ets.lookup(Valimc.RegionRoutes, {0, 0})
name = "DirRecovery"
uuid = Valimc.Connection.offline_uuid(name)
source_path = PlayerStore.path(Valimc.config(:world_path), uuid)
false = File.exists?(source_path)

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
writer = :sys.get_state(pid).resource.store
:sys.suspend(writer)

Client.send_packet(client, :play, "player_action", [
  Wire.varint(ItemTypes.action_id("drop_item")),
  Wire.position({0, 0, 0}),
  <<0, 0>>
])

pending =
  Enum.reduce_while(1..500, false, fn _, _ ->
    case :sys.get_state(pid).resource.item_pending do
      %{phase: :writing} ->
        {:halt, true}

      _ ->
        Process.sleep(5)
        {:cont, false}
    end
  end)

true = pending
{:ok, intent} = PlayerSnapshot.decode(File.read!(source_path), uuid)
1 = intent.transfer_sequence
[drop] = intent.outbox.records
6 = intent.inventory.slots[36].count
# Commit on disk while the destination owner cannot acknowledge/publicize it.
:sys.suspend(pid)
:sys.resume(writer)
{:ok, %{records: committed, receipts: receipts}} = Store.load_items(writer)
true = Enum.sort_by(committed, & &1.uuid) == Enum.sort_by([record, drop], & &1.uuid)
1 = receipts[uuid].sequence
[^record] = Items.records(:sys.get_state(pid).resource.items)
1 = map_size(World.item_snapshot({0, 0}))
{:ok, ^intent} = PlayerSnapshot.decode(File.read!(source_path), uuid)

IO.inspect(%{source: uuid, drop: drop, receipt: receipts[uuid], remaining: 6},
  label: "Pinned transfer committed without acknowledgment",
  limit: :infinity
)

old_directory = Process.whereis(Directory)
old_listener = Process.whereis(Valimc.Listener)
old_owners = for {_, p, _, _} <- DynamicSupervisor.which_children(Valimc.RegionSupervisor), do: p

old_writers =
  for {_, p, _, _} <- DynamicSupervisor.which_children(Valimc.RegionStoreSupervisor), do: p

Process.exit(old_directory, :kill)

ready =
  Enum.reduce_while(1..500, false, fn _, _ ->
    directory = Process.whereis(Directory)
    listener = Process.whereis(Valimc.Listener)

    if is_pid(directory) and directory != old_directory and is_pid(listener) and
         listener != old_listener and not Process.alive?(player.pid) and
         Enum.all?(old_owners ++ old_writers, &(not Process.alive?(&1))) do
      {:halt, true}
    else
      Process.sleep(10)
      {:cont, false}
    end
  end)

true = ready
Client.close(client)
:undefined = :ets.info(publication)
{:error, :region_unavailable} = Region.observe_blocks(owner, [])

case World.existing_owner({0, 0}) do
  {:error, :region_unavailable} -> :ok
  {:ok, {recovering, recovered_epoch}} -> true = recovering != pid and recovered_epoch != epoch
end

{:ok, replacement = {next, next_epoch}} = World.owner({0, 0})
true = next != pid and next_epoch != epoch
1 = World.get_block({2, 64, 2})
recovered_records = Items.records(:sys.get_state(next).resource.items)
true = Enum.sort_by(recovered_records, & &1.uuid) == Enum.sort_by([record, drop], & &1.uuid)
{:ok, recovered} = Region.find_item(replacement, record.uuid)

{:error, :stale_admission} =
  Directory.publish({0, 0}, admission, %{epoch: epoch, items: publication})

send(Directory, {:DOWN, monitor, :process, pid, :killed})
{:ok, ^next} = Directory.admit({0, 0})
{:ok, ^replacement} = World.existing_owner({0, 0})
{^uuid, reconnected} = Client.login(name)
reconnected = Client.load_world(reconnected)

{:ok, saved} =
  PlayerSnapshot.decode(File.read!(PlayerStore.path(Valimc.config(:world_path), uuid)), uuid)

nil = saved.outbox
1 = saved.transfer_sequence
6 = saved.inventory.slots[36].count

{:ok, :already_applied} =
  Region.apply_item_transfer(replacement, %{source: uuid, sequence: 1, records: [drop]})

^recovered_records = Items.records(:sys.get_state(next).resource.items)
:ok = Region.remove_item(recovered)
{:ok, dropped} = Region.find_item(replacement, drop.uuid)
:ok = Region.remove_item(dropped)
:ok = World.set_block({2, 64, 2}, 0)
Client.close(reconnected)

IO.inspect(
  %{
    old_owners: length(old_owners),
    old_writers: length(old_writers),
    old_handle: handle,
    recovered_handle: recovered
  },
  label: "Recovered isolated lifecycle"
)

IO.puts(
  "PASS: directory loss fences owners/writers/routes, restores durable state, replays an unacknowledged committed transfer exactly once and permits reconnect"
)
