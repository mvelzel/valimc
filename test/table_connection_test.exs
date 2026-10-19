defmodule Valimc.TableConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-table-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 10_000), 957}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "Menu#{nonce}"
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

  defp seed(ctx, slots, mode \\ :survival) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    {:ok, bytes} =
      PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, %Inventory{slots: slots}))

    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    :ok =
      World.set_block(
        target(ctx),
        Valimc.Protocol.Data.item_block(Valimc.Protocol.Data.item("crafting_table"))
      )
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    owner = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    on_exit(fn -> Client.close(client) end)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.PlayerInput.loaded?(:sys.get_state(owner).player.input) end)
    {client, owner}
  end

  defp target(ctx), do: {floor(ctx.pose.x), 64, floor(ctx.pose.z) + 3}

  defp use_table(client, ctx, hand) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(hand),
      Wire.position(target(ctx)),
      <<1, 0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
    ])
  end

  defp open(client, ctx, hand \\ 0) do
    use_table(client, ctx, hand)

    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    assert id in 1..127
    assert {12, _title} = Wire.take_varint(body)
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    assert client.inventory.container == id and length(client.inventory.items) == 46
    client
  end

  defp send_click(client, slot, button \\ 0, action \\ "pickup", id \\ nil) do
    id = id || client.inventory.container

    Client.send_packet(client, :play, "container_click", [
      Wire.varint(id),
      <<0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<0, 0>>
    ])
  end

  defp click(client, slot, button \\ 0, action \\ "pickup") do
    send_click(client, slot, button, action)
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

  test "actual table packets craft a mixed pickaxe and fence old container IDs", ctx do
    seed(ctx, %{
      36 => ItemStack.new("oak_planks"),
      37 => ItemStack.new("spruce_planks"),
      38 => ItemStack.new("birch_planks"),
      39 => ItemStack.new("stick", 2),
      45 => ItemStack.new("leather", 5)
    })

    {client, pid} = login(ctx)
    client = open(client, ctx)
    first = client.inventory.container
    client = client |> click(37) |> click(1) |> click(38) |> click(2) |> click(39) |> click(3)
    client = client |> click(40) |> click(5, 1) |> click(8, 1)
    assert hd(client.inventory.items) == ItemStack.new("wooden_pickaxe")
    assert :sys.get_state(pid).inventory.slots[0] == nil
    client = click(client, 0, 4, "swap")
    assert hd(client.inventory.items) == nil
    assert :sys.get_state(pid).inventory.slots[40] == ItemStack.new("wooden_pickaxe")
    assert :sys.get_state(pid).inventory.slots[45] == ItemStack.new("leather", 5)
    Client.send_packet(client, :play, "container_close", Wire.varint(first))
    client = inventory_until(client, &(&1.container == 0))
    assert :sys.get_state(pid).inventory.table_inputs == nil
    client = open(client, ctx)
    assert client.inventory.container != first
    send_click(client, 41, 0, "pickup", first)
    client = inventory_until(client, &(&1.container != first))
    assert :sys.get_state(pid).table_menu.id == client.inventory.container
    assert :sys.get_state(pid).inventory.carried == nil
    Client.send_packet(client, :play, "container_close", <<99>>)
    _client = inventory_until(client, &(&1.container == 0))
    assert :sys.get_state(pid).table_menu == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {fresh, pid} = login(ctx)
    assert fresh.inventory.container == 0
    assert Enum.at(fresh.inventory.items, 40) == ItemStack.new("wooden_pickaxe")
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
  end

  test "refused menu predictions correct the physical offhand outside its visible cells", ctx do
    slots = %{36 => ItemStack.new("oak_planks", 7), 45 => ItemStack.new("stone", 3)}
    seed(ctx, slots)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    send_click(client, 37, 41, "swap")
    {body, _client} = Client.await(client, :play, "set_player_inventory")
    {40, body} = Wire.take_varint(body)
    assert {:ok, stack, <<>>} = ItemStack.take(body)
    assert stack == slots[45]
    assert :sys.get_state(pid).inventory.slots == slots
    assert :sys.get_state(pid).inventory.carried == nil
  end

  test "table use preserves native both-hand and secondary precedence across modes", ctx do
    for {mode, hand, shift, slots, expected} <- [
          {:survival, 0, false, %{45 => ItemStack.new("stick")}, true},
          {:survival, 0, true, %{45 => ItemStack.new("stick")}, false},
          {:survival, 0, true, %{}, true},
          {:survival, 1, false, %{}, false},
          {:spectator, 1, true, %{36 => ItemStack.new("stick")}, true},
          {:adventure, 0, false, %{}, true}
        ] do
      seed(ctx, slots, mode)
      {client, pid} = login(ctx)
      Client.send_packet(client, :play, "player_input", <<if(shift, do: 32, else: 0)>>)

      client =
        if expected do
          open(client, ctx, hand)
        else
          use_table(client, ctx, hand)
          {_, client} = Client.await(client, :play, "block_changed_ack")
          assert :sys.get_state(pid).table_menu == nil
          client
        end

      if mode == :spectator do
        _client = click(client, 37)
        assert :sys.get_state(pid).inventory.slots == slots
        assert :sys.get_state(pid).inventory.carried == nil
      end

      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    end
  end

  test "relocation retires the menu and late grants cannot reopen it", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37) |> click(9)
    assert :sys.get_state(pid).inventory.table_inputs |> elem(8) == ItemStack.new("oak_log", 2)
    assert :ok = Connection.teleport(pid, %{ctx.pose | x: ctx.pose.x + 20})
    _client = inventory_until(client, &(&1.container == 0))
    assert :sys.get_state(pid).table_menu == nil
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert :sys.get_state(pid).inventory.slots[36] == ItemStack.new("oak_log", 2)
    assert records(ctx) == []
  end

  test "back-to-back input clicks retain FIFO ownership and removal closes the menu", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, pid} = login(ctx)
    client = open(client, ctx)
    for {slot, button} <- [{37, 0}, {1, 1}, {2, 1}], do: send_click(client, slot, button)

    client =
      inventory_until(client, fn inv ->
        Enum.at(inv.items, 1) == ItemStack.new("oak_log") and
          Enum.at(inv.items, 2) == ItemStack.new("oak_log") and inv.carried == nil
      end)

    assert :sys.get_state(pid).table_queued == 0
    {:ok, owner} = World.existing_owner(ctx.key)
    {:ok, observed} = Valimc.World.Region.observe_blocks(owner, [])

    assert {:ok, _} =
             Valimc.World.Region.set_blocks(owner, observed.revision, %{target(ctx) => 0})

    client = inventory_until(client, &(&1.container == 0))
    assert :sys.get_state(pid).table_menu == nil
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert Enum.at(client.inventory.items, 36) == ItemStack.new("oak_log", 2)
    assert records(ctx) == []
  end

  test "expired owner permission closes without applying queued output", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log")})
    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37) |> click(1)
    assert hd(client.inventory.items) == ItemStack.new("oak_planks", 4)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      send_click(client, 0)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_message, client} = Client.await(client, :play, "system_chat")
      wait(fn -> :sys.get_state(pid).table_menu == nil end)
      Valimc.TestRegionGate.resume(region)
      _client = inventory_until(client, &(&1.container == 0))
      assert :sys.get_state(pid).inventory.carried == nil
      assert :sys.get_state(pid).inventory.slots[36] == ItemStack.new("oak_log")

      refute Enum.any?(
               Inventory.contents(:sys.get_state(pid).inventory),
               &(&1 == ItemStack.new("oak_planks", 4))
             )

      assert records(ctx) == []
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "connected close locks actions while ten overflow stacks drain in two durable batches",
       ctx do
    seed(ctx, %{})
    {client, pid} = login(ctx)
    client = open(client, ctx)
    cells = Enum.map(1..9, &ItemStack.new("oak_planks", &1)) |> List.to_tuple()
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | inventory: %{
            state.inventory
            | slots: full,
              table_inputs: cells,
              carried: ItemStack.new("egg", 3)
          }
      }
    end)

    writer = :sys.get_state(pid).player_store
    :sys.suspend(writer)

    try do
      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      wait(fn -> :sys.get_state(pid).table_closing and :sys.get_state(pid).recovery != nil end)
      send_click(client, 37)

      Client.send_packet(client, :play, "container_click", [
        <<0, 0, 36::16, 0>>,
        Wire.varint(ItemTypes.input_id("pickup")),
        <<0, 0>>
      ])

      Client.send_packet(client, :play, "set_carried_item", <<2::signed-16>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_message, client} = Client.await(client, :play, "system_chat")
      assert :sys.get_state(pid).inventory.slots == full
      assert :sys.get_state(pid).inventory.selected == 0
      :sys.resume(writer)

      wait(fn ->
        not :sys.get_state(pid).table_closing and :sys.get_state(pid).recovery == nil
      end)

      _client = inventory_until(client, &(&1.container == 0 and &1.carried == nil))
      state = :sys.get_state(pid)
      assert state.inventory.slots == full and state.inventory.table_inputs == nil
      assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
      expected = [ItemStack.new("egg", 3) | Tuple.to_list(cells)]
      assert Enum.sort(Enum.map(records(ctx), & &1.stack)) == Enum.sort(expected)
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      {_fresh, fresh_pid} = login(ctx)
      assert :sys.get_state(fresh_pid).inventory.slots == full
      assert :sys.get_state(fresh_pid).inventory.table_inputs == nil
      assert length(records(ctx)) == 10 and saved(ctx).transfer_sequence == 2
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "all nine cells participate in a durable result drop", ctx do
    seed(ctx, %{
      36 => ItemStack.new("sand", 4),
      37 => ItemStack.new("gravel", 4),
      38 => ItemStack.new("red_dye")
    })

    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37)
    client = Enum.reduce(1..4, client, &click(&2, &1, 1))
    client = click(client, 38)
    client = Enum.reduce(5..8, client, &click(&2, &1, 1))
    client = client |> click(39) |> click(9)
    assert hd(client.inventory.items) == ItemStack.new("red_concrete_powder", 8)
    client = click(client, 0, 0, "throw")

    wait(fn ->
      :sys.get_state(pid).recovery == nil and
        :sys.get_state(pid).inventory.table_inputs == Tuple.duplicate(nil, 9)
    end)

    _client = inventory_until(client, &(hd(&1.items) == nil))
    assert Enum.map(records(ctx), & &1.stack) == [ItemStack.new("red_concrete_powder", 8)]
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {fresh, pid} = login(ctx)
    assert fresh.inventory.carried == nil
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert saved(ctx).transfer_sequence == 1 and length(records(ctx)) == 1
  end

  test "accepted movement outside table reach closes and returns inputs", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, pid} = login(ctx)
    _client = open(client, ctx) |> click(37) |> click(9)
    # This fixture changes the accepted player pose, rather than bypassing the
    # menu's owner query or invoking its cleanup. Native boundaries are probed separately.
    :sys.replace_state(pid, fn state ->
      %{state | player: %{state.player | x: state.player.x + 10}}
    end)

    wait(fn -> :sys.get_state(pid).table_menu == nil end)
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert :sys.get_state(pid).inventory.slots[36] == ItemStack.new("oak_log", 2)
    assert records(ctx) == []
  end

  test "replacing a region owner cannot revive its active menu permission", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, pid} = login(ctx)
    _client = open(client, ctx) |> click(37) |> click(9)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    assert :ok = Valimc.World.Region.flush(region)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    {:ok, {_fresh_owner, _}} = World.owner(ctx.key)
    wait(fn -> :sys.get_state(pid).table_menu == nil end)
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert :sys.get_state(pid).inventory.slots[36] == ItemStack.new("oak_log", 2)
    assert records(ctx) == []
  end

  test "fatal damage retires the table and drops its owned inputs once", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, pid} = login(ctx)
    _client = open(client, ctx) |> click(37) |> click(9)
    assert {:ok, :dead} = Connection.fall_damage(pid, 100)
    wait(fn -> :sys.get_state(pid).life_stage == :dead end)
    state = :sys.get_state(pid)
    assert state.table_menu == nil and not state.table_closing
    assert state.inventory.table_inputs == nil and state.inventory.carried == nil
    assert Enum.map(records(ctx), & &1.stack) == [ItemStack.new("oak_log", 2)]
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
  end

  test "a crashed connected cleanup resumes its partial table without replaying drops", ctx do
    seed(ctx, %{})
    {client, pid} = login(ctx)
    client = open(client, ctx)
    cells = Enum.map(1..9, &ItemStack.new("oak_planks", &1)) |> List.to_tuple()
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | inventory: %{
              state.inventory
              | slots: full,
                table_inputs: cells,
                carried: ItemStack.new("egg", 3)
            }
        }
      end)

      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      wait(fn -> match?(%{stage: :delivery}, :sys.get_state(pid).recovery) end)
      pending = saved(ctx)
      assert pending.transfer_sequence == 1 and length(pending.outbox.records) == 5
      assert Enum.count(Inventory.table_contents(pending.inventory), &(&1 != nil)) == 5
      writer = :sys.get_state(pid).player_store
      Process.exit(pid, :kill)
      if Process.alive?(writer), do: Process.exit(writer, :kill)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      Valimc.TestRegionGate.resume(region)
      {_fresh, fresh_pid} = login(ctx)
      assert :sys.get_state(fresh_pid).inventory.slots == full
      assert :sys.get_state(fresh_pid).inventory.table_inputs == nil
      assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
      expected = [ItemStack.new("egg", 3) | Tuple.to_list(cells)]
      assert Enum.sort(Enum.map(records(ctx), & &1.stack)) == Enum.sort(expected)
      assert length(records(ctx)) == 10
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "creative edits cannot interleave with a close waiting for its save", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)}, :creative)
    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37) |> click(9)
    writer = :sys.get_state(pid).player_store
    :sys.suspend(writer)

    try do
      wait(fn -> :sys.get_state(pid).table_job == nil end)
      send(pid, :save_player)
      wait(fn -> :sys.get_state(pid).save_ref != nil end)

      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      wait(fn -> :sys.get_state(pid).table_closing end)

      Client.send_packet(client, :play, "set_creative_mode_slot", [
        <<36::signed-16>>,
        ItemStack.encode(ItemStack.new("diamond", 64), :untrusted)
      ])

      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_message, client} = Client.await(client, :play, "system_chat")
      assert :sys.get_state(pid).inventory.slots[36] == nil
      assert elem(:sys.get_state(pid).inventory.table_inputs, 8) == ItemStack.new("oak_log", 2)
      :sys.resume(writer)
      _client = inventory_until(client, &(&1.container == 0))
      assert :sys.get_state(pid).inventory.slots == %{36 => ItemStack.new("oak_log", 2)}
      assert :sys.get_state(pid).inventory.table_inputs == nil
      assert records(ctx) == []
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "table bulk repeats before later queued clicks and commits each bounded conversion", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17), 37 => ItemStack.new("cobblestone")})
    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37) |> click(1)
    writer = :sys.get_state(pid).player_store
    :sys.suspend(writer)

    try do
      send_click(client, 0, 1, "throw")
      wait(fn -> :sys.get_state(pid).crafting_repeat != nil end)
      send_click(client, 38)
      wait(fn -> :sys.get_state(pid).table_queued == 1 end)
      assert :sys.get_state(pid).inventory.carried == nil
      :sys.resume(writer)

      wait(fn ->
        state = :sys.get_state(pid)

        state.crafting_repeat == nil and state.recovery == nil and state.table_queued == 0 and
          state.inventory.carried == ItemStack.new("cobblestone")
      end)

      assert :sys.get_state(pid).inventory.table_inputs == Tuple.duplicate(nil, 9)
      assert length(records(ctx)) == 17
      assert Enum.all?(records(ctx), &(&1.stack == ItemStack.new("oak_planks", 4)))
      assert saved(ctx).transfer_sequence == 4 and saved(ctx).outbox == nil
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "removing a table between bulk batches fences further conversion and returns12 inputs",
       ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17)})
    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37) |> click(1)
    writer = :sys.get_state(pid).player_store
    :sys.suspend(writer)

    try do
      send_click(client, 0, 1, "throw")
      wait(fn -> :sys.get_state(pid).crafting_repeat != nil end)
      :ok = World.set_block(target(ctx), 0)
      :sys.resume(writer)

      wait(fn ->
        state = :sys.get_state(pid)
        state.table_menu == nil and not state.table_closing and state.recovery == nil
      end)

      state = :sys.get_state(pid)
      assert state.crafting_repeat == nil and state.inventory.table_inputs == nil
      assert state.inventory.slots == %{36 => ItemStack.new("oak_log", 12)}
      assert length(records(ctx)) == 5
      assert Enum.all?(records(ctx), &(&1.stack == ItemStack.new("oak_planks", 4)))
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  defp saved(ctx) do
    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    saved
  end

  test "offhand result conversion commits all four remainder drops before disconnected cleanup",
       ctx do
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    seed(
      ctx,
      Map.merge(full, %{
        36 => ItemStack.new("honey_bottle", 8),
        45 => ItemStack.new("bedrock", 64)
      })
    )

    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37)
    client = Enum.reduce([1, 1, 2, 2, 4, 4, 5, 5], client, &click(&2, &1, 1))
    client = client |> click(9, 40, "swap") |> click(9) |> click(37) |> click(0, 40, "swap")
    wait(fn -> :sys.get_state(pid).recovery == nil end)
    assert :sys.get_state(pid).inventory.slots[45] == ItemStack.new("honey_block")
    assert :sys.get_state(pid).inventory.carried == nil
    assert Enum.map(records(ctx), & &1.stack) == List.duplicate(ItemStack.new("glass_bottle"), 4)
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)

    assert :sys.get_state(fresh_pid).inventory.slots ==
             Map.put(full, 45, ItemStack.new("honey_block"))

    assert :sys.get_state(fresh_pid).inventory.table_inputs == nil
    assert Enum.count(records(ctx), &(&1.stack == ItemStack.new("glass_bottle"))) == 4
    assert Enum.count(records(ctx), &(&1.stack == ItemStack.new("honey_bottle"))) == 4
    assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
  end

  defp records(ctx) do
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    Valimc.World.Items.records(:sys.get_state(pid).resource.items)
  end

  test "shift continuation rechecks table batches and finishes a drop-free last craft before close",
       ctx do
    seed(ctx, %{})
    {client, pid} = login(ctx)
    client = open(client, ctx)
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    cells =
      List.to_tuple(Enum.map(1..9, &if(&1 in [1, 2, 4, 5], do: ItemStack.new("honey_bottle", 6))))

    :sys.replace_state(pid, fn state ->
      %{state | inventory: %{state.inventory | slots: Map.delete(full, 44), table_inputs: cells}}
    end)

    send_click(client, 0, 0, "quick_move")

    wait(fn ->
      state = :sys.get_state(pid)

      state.recovery == nil and state.crafting_repeat == nil and state.table_job == nil and
        state.inventory.slots[44] == ItemStack.new("honey_block", 6)
    end)

    assert saved(ctx).transfer_sequence == 5 and saved(ctx).outbox == nil
    assert Enum.map(records(ctx), & &1.stack) == List.duplicate(ItemStack.new("glass_bottle"), 20)
    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))

    wait(fn ->
      state = :sys.get_state(pid)
      state.table_menu == nil and state.recovery == nil and not state.table_closing
    end)

    assert length(records(ctx)) == 24
    assert :sys.get_state(pid).inventory.table_inputs == nil
    assert saved(ctx).transfer_sequence == 6 and saved(ctx).outbox == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)

    assert :sys.get_state(fresh_pid).inventory.slots ==
             Map.put(full, 44, ItemStack.new("honey_block", 6))

    assert length(records(ctx)) == 24 and saved(ctx).transfer_sequence == 6
  end
end
