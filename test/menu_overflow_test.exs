defmodule Valimc.MenuOverflowTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.Health
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore, Players}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.World.Entities
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-menu-overflow-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {40_000 + rem(nonce, 3_333) * 3, 400}
    name = "Over" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    stone = %{
      ItemStack.new("stone", 64)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"overflow" => {:string, "exact"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    sword = %{ItemStack.new("iron_sword") | components: %{"minecraft:damage" => 17}}

    slots =
      Map.new(9..44, &{&1, stone})
      |> Map.merge(%{
        38 => %{stone | count: 63},
        45 => stone,
        1 => ItemStack.new("egg", 3),
        2 => ItemStack.new("dirt", 4),
        3 => sword,
        4 => ItemStack.new("diamond")
      })

    original = %Inventory{slots: slots, selected: 2, carried: %{stone | count: 10}}
    {:ok, after_inventory, drops} = Inventory.close(original)
    # Transient menu contents belong to this live session; login now cleans orphans.
    seed_inventory = %{original | slots: Map.drop(original.slots, [1, 2, 3, 4]), carried: nil}
    {:ok, seed_bytes} = PlayerState.encode(uuid, PlayerState.capture(pose, seed_inventory))

    {:ok, bytes} =
      PlayerState.encode(
        uuid,
        Map.merge(PlayerState.capture(pose, original), %{
          health: %Health{},
          air_supply: 300,
          fire_ticks: 0,
          effects: %{},
          absorption: 0.0,
          fall_distance: 0.0,
          frozen_ticks: 0,
          velocity: {0.0, 0.0, 0.0},
          last_death: nil,
          food: %Valimc.PlayerFood{},
          flying: false,
          game_mode: %Valimc.GameMode{},
          progression: %Valimc.PlayerProgression{}
        })
      )

    path = PlayerStore.path(base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, seed_bytes)

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
      path: path,
      original: original,
      after_inventory: after_inventory,
      drops: drops,
      bytes: bytes,
      seed_bytes: seed_bytes
    }
  end

  defp login(ctx, seed \\ false) do
    if seed, do: File.write!(ctx.path, ctx.seed_bytes)
    {uuid, client} = Client.login(ctx.name)
    assert uuid == ctx.uuid
    client = Client.load_world(client)

    if seed do
      {pid, state} = await_state(ctx, &(&1.phase == :play))
      inventory = %{ctx.original | infinite_materials: state.inventory.infinite_materials}
      Valimc.TestConn.replace(pid, &%{&1 | inventory: inventory})
      # This is administrative setup through the trusted leased owner, not a click.
      send(pid, :save_player)
      await_state(ctx, &(&1.save_ref == nil && saved(ctx).inventory.carried == inventory.carried))
    end

    client
  end

  defp await_state(ctx, predicate, attempts \\ 1000) do
    player = Enum.find(Players.all(), &(&1.name == ctx.name))
    state = if player, do: Valimc.TestConn.state(player.pid)

    if state && predicate.(state) do
      {player.pid, state}
    else
      assert attempts > 0
      Process.sleep(2)
      await_state(ctx, predicate, attempts - 1)
    end
  end

  defp departed(ctx, attempts \\ 1000) do
    if Enum.any?(Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid), fn {_, v} ->
         v != :closing
       end) or
         Enum.any?(:ets.tab2list(Players), fn {_, p} -> p.uuid == ctx.uuid end) do
      assert attempts > 0
      Process.sleep(2)
      departed(ctx, attempts - 1)
    end
  end

  defp saved(ctx) do
    {:ok, snapshot} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp records(ctx) do
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    Entities.records(Valimc.TestRegion.section(owner).entities.store)
  end

  defp completed(ctx) do
    await_state(ctx, fn state ->
      snapshot = saved(ctx)
      state.recovery == nil && snapshot.transfer_sequence == 1 && snapshot.outbox == nil
    end)
  end

  defp close_menu(client), do: Client.send_packet(client, :play, "container_close", <<99>>)

  # 252 fixture items alone send more packets than `await`'s default budget.
  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    client
  end

  defp verify_return(ctx, inventory) do
    assert inventory.slots == ctx.after_inventory.slots
    assert inventory.carried == nil and inventory.drag == nil and inventory.selected == 2
    assert inventory.slots[38].count == 64
    assert Enum.all?(0..4, &is_nil(inventory.slots[&1]))
  end

  test "partial return and five exact overflow stacks commit once and survive reconnect/region reload",
       ctx do
    client = login(ctx, true)
    close_menu(client)
    {_, state} = completed(ctx)
    verify_return(ctx, state.inventory)
    first = records(ctx)
    assert length(first) == 5
    assert MapSet.new(Enum.map(first, & &1.stack)) == MapSet.new(ctx.drops)
    assert Enum.sum(Enum.map(first, & &1.stack.count)) == 18
    assert Enum.all?(first, &(&1.x == ctx.pose.x and &1.z == ctx.pose.z))
    close_menu(client)
    client = barrier(client)
    assert saved(ctx).transfer_sequence == 1 and records(ctx) == first
    Client.close(client)
    departed(ctx)
    {:ok, {region, _}} = Valimc.TestWorld.item_owner(ctx.key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    second = login(ctx)
    assert second.inventory.items == Inventory.contents(ctx.after_inventory)
    assert second.inventory.carried == nil and records(ctx) == first
    close_menu(second)
    second = barrier(second)
    assert records(ctx) == first
    Client.close(second)
    departed(ctx)
  end
end
