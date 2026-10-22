defmodule Valimc.DisconnectedInventoryTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore, Players}
  alias Valimc.Player.State, as: PlayerState
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

  test "a closed socket drops the cursor and grid stacks once; logins cannot repeat them",
       ctx do
    seed(ctx, %{
      ctx.snapshot
      | inventory: %{ctx.inventory | carried: nil, slots: Map.take(ctx.inventory.slots, [38, 45])}
    })

    {uuid, client} = Client.login(ctx.name)
    assert uuid == ctx.uuid
    client = Client.load_world(client)
    p = Enum.find(Players.all(), &(&1.uuid == uuid))

    Valimc.TestConn.replace(
      p.pid,
      &%{&1 | inventory: %{ctx.inventory | infinite_materials: true}}
    )

    ref = Process.monitor(p.pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    departed(ctx)
    idle(ctx)
    owner = region(ctx)
    :ok = Valimc.World.Region.flush(elem(owner, 0))
    first = records(owner)
    verify(ctx, saved(ctx), first)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(owner, 0))
    assert records(region(ctx)) == first
    {^uuid, second} = Client.login(ctx.name)
    second = Client.load_world(second)
    assert second.inventory.carried == nil
    assert second.inventory.items == Inventory.contents(saved(ctx).inventory)
    Client.close(second)
    departed(ctx)
    idle(ctx)
    assert records(region(ctx)) == first
  end
end
