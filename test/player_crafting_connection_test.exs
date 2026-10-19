defmodule Valimc.PlayerCraftingConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-crafting-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 10_000), 850}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "Craft#{nonce}"
    uuid = Connection.offline_uuid(name)

    on_exit(fn ->
      for player <- Players.all(),
          player.name == name,
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

    %{base: base, name: name, uuid: uuid, pose: pose, key: key}
  end

  defp wait(fun, attempts \\ 1_000) do
    if value = fun.() do
      value
    else
      assert attempts > 0
      Process.sleep(5)
      wait(fun, attempts - 1)
    end
  end

  defp seed(ctx, slots) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(:survival),
        abilities: Valimc.PlayerAbilities.for_mode(:survival)
      })

    {:ok, bytes} =
      PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, %Inventory{slots: slots}))

    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    owner = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    on_exit(fn -> Client.close(client) end)
    {client, owner}
  end

  defp click(client, slot, button \\ 0, action \\ "pickup") do
    # Deliberately stale state ID: only the server's grid/cursor may authorize output.
    Client.send_packet(client, :play, "container_click", [
      <<0, 0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<0, 0>>
    ])

    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client
  end

  defp inventory_until(client, predicate) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    if predicate.(client.inventory), do: client, else: inventory_until(client, predicate)
  end

  test "live survival result packets craft one recipe, close physical items and reconnect exactly",
       ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1)
    assert hd(client.inventory.items) == ItemStack.new("oak_planks", 4)
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log", 2)
    assert Inventory.get(:sys.get_state(owner).inventory, 0) == nil
    client = click(client, 0, 1)
    assert client.inventory.carried == ItemStack.new("oak_planks", 4)
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log")
    client = click(client, 0)
    assert client.inventory.carried == ItemStack.new("oak_planks", 8)
    assert hd(client.inventory.items) == nil and Enum.at(client.inventory.items, 1) == nil
    client = click(client, 0)
    assert client.inventory.carried == ItemStack.new("oak_planks", 8)
    Client.send_packet(client, :play, "container_close", <<0>>)
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 36) == ItemStack.new("oak_planks", 8)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {fresh, owner} = login(ctx)
    assert Enum.at(fresh.inventory.items, 36) == ItemStack.new("oak_planks", 8)
    assert fresh.inventory.carried == nil
    assert Enum.all?(Enum.take(fresh.inventory.items, 5), &is_nil/1)
    inv = :sys.get_state(owner).inventory
    assert inv.slots == %{36 => ItemStack.new("oak_planks", 8)}

    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved.inventory.slots == inv.slots and saved.outbox == nil and
             saved.transfer_sequence == 0
  end

  test "mixed ingredient clicks derive sticks; incompatible/full cursors refuse",
       ctx do
    seed(ctx, %{
      36 => ItemStack.new("oak_planks", 2),
      37 => ItemStack.new("spruce_planks", 2),
      38 => ItemStack.new("stick", 61)
    })

    {client, owner} = login(ctx)
    client = client |> click(36) |> click(2) |> click(37) |> click(4)
    assert hd(client.inventory.items) == ItemStack.new("stick", 4)
    client = client |> click(38) |> click(0)
    assert client.inventory.carried == ItemStack.new("stick", 61)
    assert Enum.at(client.inventory.items, 2) == ItemStack.new("oak_planks", 2)
    client = client |> click(38) |> click(2, 1) |> click(0)
    assert client.inventory.carried == ItemStack.new("oak_planks")
    assert Enum.at(client.inventory.items, 2) == ItemStack.new("oak_planks")
    client = click(client, 2)
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 2) == ItemStack.new("oak_planks", 2)
    client = click(client, 0)
    assert client.inventory.carried == ItemStack.new("stick", 4)
    assert Enum.at(client.inventory.items, 2) == ItemStack.new("oak_planks")
    assert Enum.at(client.inventory.items, 4) == ItemStack.new("spruce_planks")
    assert Inventory.get(:sys.get_state(owner).inventory, 0) == nil
    assert :sys.get_state(owner).recovery == nil
  end

  test "result shift and empty hotbar/offhand swaps consume exact inputs", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17), 37 => ItemStack.new("oak_log", 2)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1) |> click(0, 0, "quick_move")
    assert Enum.at(client.inventory.items, 44) == ItemStack.new("oak_planks", 64)
    assert Enum.at(client.inventory.items, 43) == ItemStack.new("oak_planks", 4)
    assert hd(client.inventory.items) == nil and Enum.at(client.inventory.items, 1) == nil
    client = client |> click(37) |> click(1) |> click(0, 0, "swap")
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log")
    assert Enum.at(client.inventory.items, 36) == ItemStack.new("oak_planks", 4)
    client = click(client, 0, 8, "swap")
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log")
    client = click(client, 0, 40, "swap")
    assert Enum.at(client.inventory.items, 1) == nil
    assert Enum.at(client.inventory.items, 45) == ItemStack.new("oak_planks", 4)
    assert :sys.get_state(owner).recovery == nil
  end

  test "partial result and Q drop commit exact conversion records before reconnect", ctx do
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    slots =
      Map.merge(full, %{
        36 => ItemStack.new("oak_log", 2),
        44 => ItemStack.new("oak_planks", 62),
        45 => ItemStack.new("bedrock", 64)
      })

    seed(ctx, slots)
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1) |> click(45) |> click(36)
    client = click(client, 0, 0, "quick_move")

    wait(fn ->
      state = :sys.get_state(owner)
      state.recovery == nil and state.inventory.slots[1] == ItemStack.new("oak_log")
    end)

    client = inventory_until(client, &(Enum.at(&1.items, 1) == ItemStack.new("oak_log")))
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log")
    assert Enum.at(client.inventory.items, 44) == ItemStack.new("oak_planks", 64)
    client = click(client, 0, 0, "throw")

    wait(fn ->
      state = :sys.get_state(owner)
      state.recovery == nil and state.inventory.slots[1] == nil
    end)

    client = inventory_until(client, &(hd(&1.items) == nil and Enum.at(&1.items, 1) == nil))
    assert hd(client.inventory.items) == nil and Enum.at(client.inventory.items, 1) == nil
    assert Enum.at(client.inventory.items, 44) == ItemStack.new("oak_planks", 64)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {fresh, _} = login(ctx)
    assert Enum.at(fresh.inventory.items, 44) == ItemStack.new("oak_planks", 64)

    assert fresh.inventory.carried == nil and
             Enum.all?(Enum.take(fresh.inventory.items, 5), &is_nil/1)

    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved.transfer_sequence == 2 and saved.outbox == nil

    {:ok, ledger} =
      Valimc.World.ItemRecords.decode(
        File.read!(Valimc.World.Store.item_path(ctx.base, ctx.key)),
        ctx.key
      )

    assert Enum.map(ledger.records, & &1.stack) |> Enum.sort_by(& &1.count) == [
             ItemStack.new("oak_planks", 2),
             ItemStack.new("oak_planks", 4)
           ]

    assert map_size(Valimc.World.item_snapshot(ctx.key)) == 2
  end

  test "creative input edits replicate their derived result and an invented result edit corrects it",
       ctx do
    seed(ctx, %{})
    {client, owner} = login(ctx)

    :sys.replace_state(owner, fn state ->
      %{state | inventory: %{state.inventory | infinite_materials: true}}
    end)

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<4::16>>,
      ItemStack.encode(ItemStack.new("oak_log", 2), :untrusted)
    ])

    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {_, <<4::signed-16, bytes::binary>>} = Wire.take_varint(body)
    assert ItemStack.decode(bytes) == {:ok, ItemStack.new("oak_log", 2)}
    {body, client} = Client.await(client, :play, "container_set_slot")
    {0, body} = Wire.take_varint(body)
    {_, <<0::signed-16, bytes::binary>>} = Wire.take_varint(body)
    assert ItemStack.decode(bytes) == {:ok, ItemStack.new("oak_planks", 4)}

    Client.send_packet(client, :play, "set_creative_mode_slot", [
      <<0::16>>,
      ItemStack.encode(ItemStack.new("diamond", 64), :untrusted)
    ])

    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    assert hd(client.inventory.items) == ItemStack.new("oak_planks", 4)
    assert :sys.get_state(owner).inventory.slots == %{4 => ItemStack.new("oak_log", 2)}
    {_, client} = Client.await(client, :play, "set_cursor_item")
    client = click(client, 0, 2, "clone")
    assert client.inventory.carried == ItemStack.new("oak_planks", 64)
    assert Enum.at(client.inventory.items, 4) == ItemStack.new("oak_log", 2)

    :sys.replace_state(owner, fn state ->
      %{state | inventory: %{state.inventory | infinite_materials: false, carried: nil}}
    end)

    client = click(client, 0, 2, "clone")
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 4) == ItemStack.new("oak_log", 2)
  end

  test "Ctrl-Q repeats17 crafts in four durable batches and reconnect never repeats them", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1) |> click(0, 1, "throw")

    wait(fn ->
      state = :sys.get_state(owner)
      state.recovery == nil and state.crafting_repeat == nil and state.inventory.slots == %{}
    end)

    _client = inventory_until(client, &(Enum.at(&1.items, 1) == nil))
    assert length(records(ctx)) == 17
    assert Enum.all?(records(ctx), &(&1.stack == ItemStack.new("oak_planks", 4)))
    assert saved(ctx).transfer_sequence == 4 and saved(ctx).outbox == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)
    assert :sys.get_state(fresh_pid).crafting_repeat == nil
    assert length(records(ctx)) == 17 and saved(ctx).transfer_sequence == 4
  end

  test "closing while bulk waits for its source cancels continuation and returns unspent inputs",
       ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1)
    writer = :sys.get_state(owner).player_store
    :sys.suspend(writer)

    try do
      _client = click(client, 0, 1, "throw")
      assert :sys.get_state(owner).crafting_repeat != nil
      Client.send_packet(client, :play, "container_close", <<0>>)
      wait(fn -> :sys.get_state(owner).table_closing end)
      assert :sys.get_state(owner).crafting_repeat == nil
      :sys.resume(writer)

      wait(fn ->
        state = :sys.get_state(owner)
        state.recovery == nil and not state.table_closing
      end)

      assert :sys.get_state(owner).inventory.slots == %{36 => ItemStack.new("oak_log", 12)}
      assert length(records(ctx)) == 5
      assert Enum.all?(records(ctx), &(&1.stack == ItemStack.new("oak_planks", 4)))
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "crash after the first bulk source recovers committed outputs and cleans unspent inputs",
       ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1)
    {:ok, {region, _}} = Valimc.World.existing_owner(ctx.key)
    :sys.suspend(region)

    try do
      _client = click(client, 0, 1, "throw")
      wait(fn -> match?(%{stage: :delivery}, :sys.get_state(owner).recovery) end)
      pending = saved(ctx)
      assert pending.inventory.slots == %{1 => ItemStack.new("oak_log", 12)}
      assert pending.transfer_sequence == 1 and length(pending.outbox.records) == 5
      writer = :sys.get_state(owner).player_store
      Process.exit(owner, :kill)
      if Process.alive?(writer), do: Process.exit(writer, :kill)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      :sys.resume(region)
      {_fresh, fresh_pid} = login(ctx)
      assert :sys.get_state(fresh_pid).inventory.slots == %{}
      assert :sys.get_state(fresh_pid).crafting_repeat == nil

      assert Enum.sort(Enum.map(records(ctx), & &1.stack)) ==
               Enum.sort([
                 ItemStack.new("oak_log", 12) | List.duplicate(ItemStack.new("oak_planks", 4), 5)
               ])

      assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
    after
      if Process.alive?(region), do: :sys.resume(region)
    end
  end

  defp saved(ctx) do
    {:ok, snapshot} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    snapshot
  end

  test "death during a prepared bulk batch commits five results and drops only unspent inputs",
       ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17)})
    {client, owner} = login(ctx)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.PlayerInput.loaded?(:sys.get_state(owner).player.input) end)
    client = client |> click(36) |> click(1)
    writer = :sys.get_state(owner).player_store
    :sys.suspend(writer)

    try do
      _client = click(client, 0, 1, "throw")
      assert {:ok, :dead} = Connection.fall_damage(owner, 100)
      :sys.resume(writer)
      wait(fn -> :sys.get_state(owner).life_stage == :dead end)
      state = :sys.get_state(owner)
      assert state.crafting_repeat == nil and state.inventory.slots == %{}

      assert Enum.sort(Enum.map(records(ctx), & &1.stack)) ==
               Enum.sort([
                 ItemStack.new("oak_log", 12) | List.duplicate(ItemStack.new("oak_planks", 4), 5)
               ])

      assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  defp records(ctx) do
    {:ok, {pid, _}} = Valimc.World.item_owner(ctx.key)
    Valimc.World.Items.records(:sys.get_state(pid).resource.items)
  end

  test "pickup remainders commit with their carried output and survive disconnect cleanup", ctx do
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    seed(
      ctx,
      Map.merge(full, %{
        36 => ItemStack.new("honey_bottle", 2),
        45 => ItemStack.new("bedrock", 64)
      })
    )

    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1) |> click(45) |> click(36) |> click(0)
    wait(fn -> :sys.get_state(owner).recovery == nil end)
    client = inventory_until(client, &(&1.carried == ItemStack.new("sugar", 3)))
    assert :sys.get_state(owner).inventory.slots[1] == ItemStack.new("honey_bottle")
    assert Enum.map(records(ctx), & &1.stack) == [ItemStack.new("glass_bottle")]
    assert saved(ctx).transfer_sequence == 1
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)
    assert :sys.get_state(fresh_pid).inventory.slots == full
    assert :sys.get_state(fresh_pid).inventory.carried == nil

    assert Enum.sort(Enum.map(records(ctx), & &1.stack)) ==
             Enum.sort([
               ItemStack.new("glass_bottle"),
               ItemStack.new("honey_bottle"),
               ItemStack.new("sugar", 3)
             ])

    assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
  end

  test "bulk bottle conversion continues four-record batches then closes its final physical bottle",
       ctx do
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    seed(
      ctx,
      Map.merge(full, %{
        36 => ItemStack.new("honey_bottle", 6),
        45 => ItemStack.new("bedrock", 64)
      })
    )

    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1) |> click(45) |> click(36) |> click(0, 1, "throw")

    wait(fn ->
      state = :sys.get_state(owner)

      state.recovery == nil and state.crafting_repeat == nil and
        state.inventory.slots[1] == ItemStack.new("glass_bottle")
    end)

    assert saved(ctx).transfer_sequence == 3 and saved(ctx).outbox == nil
    assert Enum.count(records(ctx), &(&1.stack == ItemStack.new("sugar", 3))) == 6
    assert Enum.count(records(ctx), &(&1.stack == ItemStack.new("glass_bottle"))) == 5
    Client.send_packet(client, :play, "container_close", <<0>>)

    wait(fn ->
      state = :sys.get_state(owner)
      state.recovery == nil and not state.table_closing and state.inventory.slots == full
    end)

    assert saved(ctx).transfer_sequence == 4 and saved(ctx).outbox == nil
    assert Enum.count(records(ctx), &(&1.stack == ItemStack.new("glass_bottle"))) == 6
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)
    assert :sys.get_state(fresh_pid).inventory.slots == full
    assert length(records(ctx)) == 12 and saved(ctx).transfer_sequence == 4
  end
end
