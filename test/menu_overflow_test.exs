defmodule Valimc.MenuOverflowTest do
  use ExUnit.Case, async: false
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.World.{ItemRecords, Items, Region, Store}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-menu-overflow-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {40_000 + rem(nonce, 10_000), 400}
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
    {:ok, seed_bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(pose, seed_inventory))

    {:ok, bytes} =
      PlayerSnapshot.encode(
        uuid,
        Map.merge(PlayerSnapshot.capture(pose, original), %{
          fall_distance: 0.0,
          flying: false,
          game_mode: %Valimc.GameMode{}
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

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
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
      :sys.replace_state(pid, &%{&1 | inventory: inventory})
      # This is administrative setup through the trusted leased owner, not a click.
      send(pid, :save_player)
      await_state(ctx, &(&1.save_ref == nil && saved(ctx).inventory.carried == inventory.carried))
    end

    client
  end

  defp await_state(ctx, predicate, attempts \\ 1000) do
    player = Enum.find(Players.all(), &(&1.name == ctx.name))
    state = if player, do: :sys.get_state(player.pid)

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
    {:ok, snapshot} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp records(ctx) do
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    Items.records(:sys.get_state(pid).resource.items)
  end

  defp completed(ctx) do
    await_state(ctx, fn state ->
      snapshot = saved(ctx)
      state.recovery == nil && snapshot.transfer_sequence == 1 && snapshot.outbox == nil
    end)
  end

  defp close_menu(client), do: Client.send_packet(client, :play, "container_close", <<99>>)

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await(client, :play, "system_chat")
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
    {:ok, {region, _}} = World.item_owner(ctx.key)
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

  test "stalled source does not publish partial merges and gates repeat close/click/swap while movement stays live",
       ctx do
    client = login(ctx, true)
    {pid, state} = await_state(ctx, &(&1.recovery == nil))
    :sys.suspend(state.player_store)

    try do
      close_menu(client)
      {^pid, pending} = await_state(ctx, &(&1.recovery != nil && &1.recovery.stage == :prepare))
      assert length(pending.recovery.plan.records) == 5
      close_menu(client)

      Client.send_packet(client, :play, "container_click", [
        <<0, 0, -999::signed-16, 0>>,
        Wire.varint(ItemTypes.input_id("pickup")),
        <<0, 0>>
      ])

      Client.send_packet(client, :play, "player_action", [
        Wire.varint(ItemTypes.action_id("swap_item_with_offhand")),
        Wire.position({0, 0, 0}),
        <<0, 0>>
      ])

      Client.send_packet(
        client,
        :play,
        "move_player_pos",
        <<ctx.pose.x + 1::float-64, 64.0::float-64, ctx.pose.z::float-64, 1>>
      )

      client = barrier(client)
      Client.await_position(pid, %{x: ctx.pose.x + 1})
      frozen = :sys.get_state(pid)

      assert frozen.inventory.slots == ctx.original.slots and
               frozen.inventory.carried == ctx.original.carried

      assert frozen.player.x == ctx.pose.x + 1 and records(ctx) == []
      assert File.read!(ctx.path) == ctx.bytes
      :sys.resume(state.player_store)
      {^pid, done} = completed(ctx)
      verify_return(ctx, done.inventory)
      assert done.player.x == ctx.pose.x + 1

      assert MapSet.new(Enum.map(records(ctx), & &1.uuid)) ==
               MapSet.new(Enum.map(pending.recovery.plan.records, & &1.uuid))

      Client.close(client)
    after
      if Process.alive?(state.player_store), do: :sys.resume(state.player_store)
      Client.close(client)
      departed(ctx)
    end
  end

  test "destination stalls expose no partial batch; disconnect recovery delivers the same five UUIDs",
       ctx do
    client = login(ctx, true)
    {:ok, {region, _}} = World.item_owner(ctx.key)
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      close_menu(client)

      {_, pending} =
        await_state(
          ctx,
          &(&1.recovery != nil && &1.recovery.stage == :delivery &&
              :sys.get_state(region).resource.item_pending != nil)
        )

      snapshot = saved(ctx)
      assert length(snapshot.outbox.records) == 5
      verify_return(ctx, pending.inventory)
      assert World.item_snapshot(ctx.key) == %{}
      Client.close(client)
      departed(ctx)
      :sys.resume(writer)
      second = login(ctx)
      completed(ctx)
      assert second.inventory.items == Inventory.contents(ctx.after_inventory)

      assert MapSet.new(Enum.map(records(ctx), & &1.uuid)) ==
               MapSet.new(Enum.map(snapshot.outbox.records, & &1.uuid))

      assert length(records(ctx)) == 5
      Client.close(second)
      departed(ctx)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Client.close(client)
      departed(ctx)
    end
  end

  test "disabled storage and failed source writes cannot publish partial returns or world records",
       ctx do
    for failure <- [:disabled, :write_failure] do
      client = login(ctx, true)
      {pid, state} = await_state(ctx, &(&1.recovery == nil))

      if failure == :disabled do
        :sys.replace_state(state.player_store, &%{&1 | path: nil})
        close_menu(client)
        {_, client} = Client.await(client, :play, "system_chat")
        client = barrier(client)
        frozen = :sys.get_state(pid)
        assert frozen.recovery == nil and frozen.inventory.slots == ctx.original.slots
        assert frozen.inventory.carried == ctx.original.carried
        Client.close(client)
        departed(ctx)
      else
        File.write!(Path.join(ctx.base, "blocked"), "not a directory")

        :sys.replace_state(
          state.player_store,
          &%{&1 | path: Path.join(ctx.base, "blocked/player.pose")}
        )

        capture_log(fn ->
          close_menu(client)
          {_, _} = Client.await(client, :play, "disconnect")
          Client.close(client)
          departed(ctx)
        end)
      end

      assert records(ctx) == [] and File.read!(ctx.path) == ctx.bytes
    end
  end

  test "normal-save admission preserves the entire overflow plan until a fresh close retries",
       ctx do
    client = login(ctx, true)
    {pid, state} = await_state(ctx, &(&1.recovery == nil))
    :sys.suspend(state.player_store)

    try do
      send(pid, :save_player)
      await_state(ctx, &(&1.save_ref != nil))
      close_menu(client)
      client = barrier(client)
      frozen = :sys.get_state(pid)
      assert frozen.recovery == nil and frozen.inventory.slots == ctx.original.slots
      assert frozen.inventory.carried == ctx.original.carried and records(ctx) == []
      :sys.resume(state.player_store)
      await_state(ctx, &(&1.save_ref == nil))
      close_menu(client)
      {_, done} = completed(ctx)
      verify_return(ctx, done.inventory)
      assert length(records(ctx)) == 5
      Client.close(client)
    after
      if Process.alive?(state.player_store), do: :sys.resume(state.player_store)
      Client.close(client)
      departed(ctx)
    end
  end

  test "capacity failure retains all five remainders and publishes the batch only after enough space exists",
       ctx do
    fixture =
      for _ <- 1..252,
          do: %{
            uuid: :crypto.strong_rand_bytes(16),
            x: ctx.pose.x,
            y: 64.5,
            z: ctx.pose.z,
            stack: ItemStack.new("stone")
          }

    {:ok, bytes} = ItemRecords.encode(ctx.key, fixture)
    item_path = Store.item_path(ctx.base, ctx.key)
    File.mkdir_p!(Path.dirname(item_path))
    File.write!(item_path, bytes)
    client = login(ctx, true)
    close_menu(client)

    {_, pending} =
      await_state(
        ctx,
        &(&1.recovery != nil && &1.recovery.stage == :retry && &1.recovery.attempts > 0)
      )

    snapshot = saved(ctx)
    assert snapshot.outbox != nil and length(snapshot.outbox.records) == 5
    verify_return(ctx, pending.inventory)
    assert length(records(ctx)) == 252

    assert MapSet.new(Enum.map(records(ctx), & &1.uuid)) ==
             MapSet.new(Enum.map(fixture, & &1.uuid))

    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, handle} = Region.find_item(owner, hd(fixture).uuid)
    assert :ok = Region.remove_item(handle)
    completed(ctx)
    final = records(ctx)
    assert length(final) == 256
    dropped_ids = MapSet.new(Enum.map(snapshot.outbox.records, & &1.uuid))
    assert length(Enum.filter(final, &MapSet.member?(dropped_ids, &1.uuid))) == 5
    close_menu(client)
    client = barrier(client)
    assert length(records(ctx)) == 256 and saved(ctx).transfer_sequence == 1
    Client.close(client)
    departed(ctx)
  end
end
