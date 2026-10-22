defmodule Valimc.DisconnectedInventoryTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore, Players}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.World.Region
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-disconnected-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 3_333) * 3, 400}
    name = "Gone" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    stone = %{
      ItemStack.new("stone", 10)
      | components: %{
          "minecraft:custom_data" => {:compound, %{"disconnect" => {:string, "exact"}}},
          "minecraft:enchantment_glint_override" => true
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    inventory = %Inventory{
      selected: 2,
      carried: stone,
      drag: %{mode: 0, slots: MapSet.new([9])},
      slots: %{
        1 => ItemStack.new("egg", 3),
        2 => ItemStack.new("dirt", 4),
        3 => %{ItemStack.new("iron_sword") | components: %{"minecraft:damage" => 17}},
        4 => ItemStack.new("diamond"),
        38 => %{stone | count: 63},
        45 => ItemStack.new("egg", 3)
      }
    }

    snapshot = PlayerState.capture(pose, inventory)
    path = PlayerStore.path(base, uuid)

    on_exit(fn ->
      for {pid, p} <- :ets.tab2list(Players),
          p.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      name: name,
      uuid: uuid,
      pose: pose,
      inventory: inventory,
      snapshot: snapshot,
      path: path
    }
  end

  defp wait(predicate, _budget \\ nil), do: Valimc.TestWait.until(predicate)

  defp saved(ctx) do
    {:ok, snapshot} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp seed(ctx, snapshot) do
    {:ok, bytes} = PlayerState.encode(ctx.uuid, snapshot)
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp region(ctx) do
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    owner
  end

  # Durable records of that owner's region (owner memory may hold in-flight writes).
  defp records(owner) do
    key = Valimc.TestRegion.section(owner).key

    case Valimc.TestDisk.read(Valimc.config(:world_path), key, :items) do
      nil -> []
      saved -> saved.records
    end
  end

  defp verify(ctx, snapshot, records) do
    assert snapshot.inventory.slots == Map.take(ctx.inventory.slots, [38, 45])
    assert snapshot.inventory.carried == nil and snapshot.inventory.selected == 2
    assert snapshot.outbox == nil

    assert Enum.map(records, & &1.stack) |> MapSet.new() ==
             MapSet.new([ctx.inventory.carried | Enum.map(1..4, &ctx.inventory.slots[&1])])

    assert length(records) == 5

    assert Enum.all?(
             records,
             &(&1.x == ctx.pose.x and &1.z == ctx.pose.z and
                 &1.y == ctx.pose.y + 1.3199999928474426)
           )
  end

  defp departed(ctx) do
    wait(fn -> not Enum.any?(:ets.tab2list(Players), fn {_, p} -> p.uuid == ctx.uuid end) end)
  end

  defp idle(ctx), do: wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)

  test "socket exit commits all five whole stacks offline and normal/restarted login cannot repeat them",
       ctx do
    seed(ctx, %{
      ctx.snapshot
      | inventory: %{ctx.inventory | carried: nil, slots: Map.take(ctx.inventory.slots, [38, 45])}
    })

    {uuid, client} = Client.login(ctx.name)
    assert uuid == ctx.uuid
    client = Client.load_world(client)
    p = Enum.find(Players.all(), &(&1.uuid == uuid))
    :sys.replace_state(p.pid, &%{&1 | inventory: %{ctx.inventory | infinite_materials: true}})
    ref = Process.monitor(p.pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    departed(ctx)
    idle(ctx)
    owner = region(ctx)
    first = records(owner)
    verify(ctx, saved(ctx), first)
    assert saved(ctx).transfer_sequence == 1
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(owner, 0))
    assert records(region(ctx)) == first
    {^uuid, second} = Client.login(ctx.name)
    second = Client.load_world(second)
    assert second.inventory.carried == nil
    assert second.inventory.items == Inventory.contents(saved(ctx).inventory)
    Client.close(second)
    departed(ctx)
    idle(ctx)
    assert records(region(ctx)) == first and saved(ctx).transfer_sequence == 1
  end

  test "reconnect adopts a closing writer, fences old messages and replays its exact journal",
       ctx do
    owner = region(ctx)
    disk = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(disk)
    parent = self()

    old_owner =
      spawn(fn ->
        {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
        :ok = PlayerStore.close_session(writer, fence, ctx.snapshot)
        send(parent, {:closed, writer, fence})
      end)

    try do
      assert_receive {:closed, writer, old_fence}

      closing =
        wait(fn ->
          state = :sys.get_state(writer)

          if state.closing.job && Valimc.TestRegion.writing?(Valimc.TestRegion.section(owner)),
            do: state
        end)

      assert not Process.alive?(old_owner) and Process.alive?(writer)
      pending = saved(ctx)
      assert length(pending.outbox.records) == 5 and records(owner) == []
      {:ok, ^writer, adopted, fence} = PlayerStore.open(ctx.uuid)
      assert fence != old_fence and adopted.outbox == pending.outbox
      refute adopted.inventory.infinite_materials
      assert adopted.inventory.state_id == 0 and adopted.inventory.drag == nil
      ref = make_ref()
      PlayerStore.checkpoint(writer, old_fence, ctx.snapshot, ref)
      assert_receive {:player_saved, ^ref, {:error, :stale_player_snapshot}}

      send(
        writer,
        {:transfer_delivered, closing.closing.job.pid, closing.closing.job.token, {:ok, :applied}}
      )

      send(writer, {:close_deadline, closing.closing.id})
      send(writer, {:retry_close, closing.closing.id, closing.closing.retry_token})
      send(writer, {:deliver_close, closing.closing.id})
      send(writer, {:DOWN, closing.monitor, :process, old_owner, :normal})
      assert :sys.get_state(writer).snapshot.outbox == pending.outbox
      assert :sys.get_state(writer).closing == nil
      :sys.resume(disk)
      wait(fn -> not Valimc.TestRegion.writing?(Valimc.TestRegion.section(owner)) end)
      {:ok, _, request, _} = PlayerState.transfer_request(ctx.uuid, adopted)
      {:ok, handle} = Valimc.TestWorld.item_owner(ctx.key)
      assert {:ok, :already_applied} = Region.apply_item_transfer(handle, request)
      ref = make_ref()
      PlayerStore.complete_transfer(writer, fence, ref)
      assert_receive {:player_transfer_saved, ^ref, {:ok, fence, completed}}
      verify(ctx, completed, records(owner))

      assert MapSet.new(Enum.map(records(owner), & &1.uuid)) ==
               MapSet.new(Enum.map(pending.outbox.records, & &1.uuid))

      assert :ok = PlayerStore.close(writer, fence, completed)
    after
      if Process.alive?(disk), do: :sys.resume(disk)
    end
  end
end
