defmodule Valimc.TableInventoryRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{
    Connection,
    Inventory,
    Players,
    PlayerSnapshot,
    PlayerStore,
    PlayerTransfers,
    World
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Items, Region}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-table-recovery-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {80_000 + rem(nonce, 10_000), 956}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "Table#{nonce}"
    uuid = Connection.offline_uuid(name)
    cells = Enum.map(1..9, &ItemStack.new("oak_planks", &1)) |> List.to_tuple()

    inventory = %Inventory{
      table_inputs: cells,
      slots: %{36 => ItemStack.new("stone", 7)},
      carried: ItemStack.new("egg", 3)
    }

    snapshot = PlayerSnapshot.capture(pose, inventory)

    on_exit(fn ->
      for player <- Players.all(),
          player.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, uuid: uuid, name: name, snapshot: snapshot, inventory: inventory}
  end

  defp wait(fun, attempts \\ 1_000) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert attempts > 0
        Process.sleep(5)
        wait(fun, attempts - 1)
    end
  end

  defp idle(ctx), do: wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)

  defp saved(ctx),
    do: PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

  defp records(ctx) do
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    Items.records(Valimc.TestConn.state(pid).resource.items)
  end

  defp owned(ctx), do: [ctx.inventory.carried | Tuple.to_list(ctx.inventory.table_inputs)]

  test "an empty recovered table closes before login without a transfer or extra wire slots",
       ctx do
    inventory = %Inventory{
      slots: ctx.inventory.slots,
      table_inputs: List.duplicate(nil, 9) |> List.to_tuple()
    }

    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    assert :ok = PlayerStore.close(writer, fence, %{ctx.snapshot | inventory: inventory})
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    on_exit(fn -> Client.close(client) end)
    owner = Enum.find(Players.all(), &(&1.uuid == ctx.uuid)).pid
    assert :sys.get_state(owner).inventory.table_inputs == nil
    assert length(client.inventory.items) == 46 and client.inventory.carried == nil
    Client.close(client)
    idle(ctx)
    assert {:ok, final} = saved(ctx)

    assert final.transfer_sequence == 0 and final.outbox == nil and
             final.inventory.table_inputs == nil

    assert records(ctx) == []
  end

  test "disconnected writer drains ten owned inputs through two five-record journals", ctx do
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    assert :ok = PlayerStore.close_session(writer, fence, ctx.snapshot)
    idle(ctx)
    assert {:ok, final} = saved(ctx)
    assert final.inventory.table_inputs == nil and final.inventory.carried == nil
    assert final.inventory.slots == ctx.inventory.slots
    assert final.transfer_sequence == 2 and final.outbox == nil
    assert Enum.sort(Enum.map(records(ctx), & &1.stack)) == Enum.sort(owned(ctx))
    {:ok, writer, ^final, fence} = PlayerStore.open(ctx.uuid)
    assert :ok = PlayerStore.close_session(writer, fence, final)
    idle(ctx)
    assert {:ok, ^final} = saved(ctx)
    assert length(records(ctx)) == 10
  end

  test "TCP login resumes a persisted partial table after writer/destination restart without repeating a removed drop",
       ctx do
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    {:ok, next, key, batch} = PlayerTransfers.plan_disconnect(ctx.snapshot)

    assert length(batch) == 5 and
             Enum.count(Inventory.table_contents(next.inventory), &(&1 != nil)) == 5

    ref = make_ref()
    PlayerStore.prepare_transfer(writer, fence, ctx.snapshot, next, key, batch, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _fence, pending}}, 1_500
    assert {:ok, ^key, request, _} = PlayerSnapshot.transfer_request(ctx.uuid, pending)
    {:ok, {region, _} = destination} = World.item_owner(key)
    assert {:ok, :applied} = Region.apply_item_transfer(destination, request)
    [removed | _] = batch
    {:ok, handle} = Region.find_item(destination, removed.uuid)
    assert :ok = Region.remove_item(handle)
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1_000
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)

    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    on_exit(fn -> Client.close(client) end)
    owner = Enum.find(Players.all(), &(&1.uuid == ctx.uuid)).pid
    assert :sys.get_state(owner).inventory.table_inputs == nil
    assert Enum.at(client.inventory.items, 36) == ctx.inventory.slots[36]
    assert length(client.inventory.items) == 46 and client.inventory.carried == nil
    assert {:ok, final} = saved(ctx)

    assert final.transfer_sequence == 2 and final.outbox == nil and
             final.inventory.table_inputs == nil

    assert Enum.sort(Enum.map(records(ctx), & &1.stack)) ==
             Enum.sort(owned(ctx) -- [removed.stack])

    refute Enum.any?(records(ctx), &(&1.uuid == removed.uuid))
    Client.close(client)
    idle(ctx)
    {_, fresh} = Client.login(ctx.name)
    fresh = Client.load_world(fresh)
    on_exit(fn -> Client.close(fresh) end)
    assert fresh.inventory.items == client.inventory.items and fresh.inventory.carried == nil
    assert length(records(ctx)) == 9
  end
end
