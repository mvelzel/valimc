defmodule Valimc.ChestConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.World.{Containers, Region, Store}
  alias Valimc.TestClient, as: Client
  @chest hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  setup do
    nonce = System.unique_integer([:positive])

    base =
      Path.join(System.tmp_dir!(), "valimc-chest-view-#{System.os_time(:nanosecond)}-#{nonce}")

    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {72_000 + rem(nonce, 10_000), 961}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "ChestV#{rem(nonce, 1_000_000_000)}"
    uuid = Connection.offline_uuid(name)

    on_exit(fn ->
      for player <- Players.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for {registry, supervisor, identity} <- [
            {Valimc.PlayerStoreRegistry, Valimc.PlayerStoreSupervisor, uuid},
            {Valimc.RegionRegistry, Valimc.RegionSupervisor, key},
            {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor, key}
          ],
          {pid, _} <- Registry.lookup(registry, identity),
          do: DynamicSupervisor.terminate_child(supervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      name: name,
      uuid: uuid,
      key: key,
      pose: pose,
      position: {floor(pose.x), 64, floor(pose.z) + 3}
    }
  end

  defp wait(fun, left \\ 1000) do
    if value = fun.() do
      value
    else
      assert left > 0
      Process.sleep(5)
      wait(fun, left - 1)
    end
  end

  defp seed(ctx, mode \\ :survival, present \\ true, stock \\ ItemStack.new("diamond", 3)) do
    inventory = %Inventory{slots: %{36 => ItemStack.new("oak_planks", 8)}}

    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    if present do
      {:ok, containers, entry} = Containers.create(%Containers{}, ctx.key, ctx.position, 3)
      slots = put_elem(entry.slots, 0, stock)
      {:ok, containers, _} = Containers.replace(containers, ctx.position, entry.revision, slots)
      {:ok, containers, _} = Valimc.World.ContainerTransfers.reserve(containers, ctx.uuid)
      {:ok, bytes} = Containers.encode(ctx.key, containers)
      path = Store.container_path(ctx.base, ctx.key)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    {rx, rz} = ctx.key

    File.write!(
      Path.join(ctx.base, "r.#{rx}.#{rz}.etf"),
      :erlang.term_to_binary({:valimc_region, 1, %{ctx.position => @chest}})
    )

    :ok = World.set_block(ctx.position, @chest)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.PlayerInput.loaded?(:sys.get_state(pid).player.input) end)

    on_exit(fn ->
      Client.close(client)

      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)
    end)

    {client, pid}
  end

  defp use_chest(client, ctx, hand \\ 0) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(hand),
      Wire.position(ctx.position),
      # The occupied underside keeps secondary-use dispatch negatives from
      # placing the held planks above this chest and obstructing a later case.
      <<0, 0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
    ])
  end

  defp content(client, predicate \\ fn _ -> true end) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    if predicate.(client.inventory), do: client, else: content(client, predicate)
  end

  defp open(client, ctx, hand \\ 0) do
    use_chest(client, ctx, hand)
    {_, client} = Client.await(client, :play, "block_changed_ack")
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    assert :sys.get_state(pid).table_menu != nil
    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    assert id in 1..127
    assert {2, _} = Wire.take_varint(body)
    client = content(client)
    assert client.inventory.container == id and length(client.inventory.items) == 63
    client
  end

  defp send_click(client, slot, button \\ 0, action \\ "pickup", id \\ nil) do
    Client.send_packet(client, :play, "container_click", [
      Wire.varint(id || client.inventory.container),
      <<0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<1, slot::signed-16, 0, 0>>
    ])
  end

  defp click(client, slot, button, action, expected) do
    send_click(client, slot, button, action)
    content(client, expected)
  end

  test "late chest predictions after forced close are ignored without disconnecting", ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    old = client.inventory.container
    client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 0.1})
    assert :sys.get_state(pid).table_menu == nil
    send_click(client, 54, 0, "pickup", old)
    {_, client} = Client.await(client, :play, "container_close")
    _client = content(client, &(&1.container == 0))
    assert :sys.get_state(pid).inventory.slots == %{36 => ItemStack.new("oak_planks", 8)}
    assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
  end

  defp saved(ctx) do
    {:ok, snapshot} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    snapshot
  end

  defp stored(ctx) do
    {:ok, containers} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    containers
  end

  test "live pickup/split/merge/shift/number/offhand exchanges seal once and reconnect exactly",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    assert hd(client.inventory.items) == ItemStack.new("diamond", 3)
    assert Enum.at(client.inventory.items, 54) == ItemStack.new("oak_planks", 8)
    assert :sys.get_state(pid).inventory.table_inputs == nil
    client = click(client, 54, 0, "pickup", &(&1.carried == ItemStack.new("oak_planks", 8)))

    client =
      click(
        client,
        1,
        1,
        "pickup",
        &(Enum.at(&1.items, 1) == ItemStack.new("oak_planks") and
            &1.carried == ItemStack.new("oak_planks", 7))
      )

    client =
      click(
        client,
        1,
        0,
        "pickup",
        &(Enum.at(&1.items, 1) == ItemStack.new("oak_planks", 8) and &1.carried == nil)
      )

    assert {:error, :occupied_container} = World.remove_block(ctx.position)

    client =
      click(
        client,
        1,
        0,
        "quick_move",
        &(Enum.at(&1.items, 62) == ItemStack.new("oak_planks", 8) and Enum.at(&1.items, 1) == nil)
      )

    client =
      click(
        client,
        0,
        0,
        "swap",
        &(hd(&1.items) == nil and Enum.at(&1.items, 54) == ItemStack.new("diamond", 3))
      )

    client = click(client, 62, 40, "swap", &(Enum.at(&1.items, 62) == nil))
    assert :sys.get_state(pid).inventory.slots[45] == ItemStack.new("oak_planks", 8)
    client = click(client, 0, 40, "swap", &(hd(&1.items) == ItemStack.new("oak_planks", 8)))

    client =
      click(
        client,
        0,
        0,
        "quick_move",
        &(hd(&1.items) == nil and Enum.at(&1.items, 62) == ItemStack.new("oak_planks", 8))
      )

    client =
      click(
        client,
        62,
        1,
        "pickup",
        &(&1.carried == ItemStack.new("oak_planks", 4) and
            Enum.at(&1.items, 62) == ItemStack.new("oak_planks", 4))
      )

    client =
      click(
        client,
        61,
        0,
        "pickup",
        &(&1.carried == nil and Enum.at(&1.items, 61) == ItemStack.new("oak_planks", 4))
      )

    assert saved(ctx).transfer_sequence == 10 and saved(ctx).outbox == nil

    for {action, id} <- [{"throw", client.inventory.container}, {"pickup", 99}] do
      send_click(client, 54, 0, action, id)
      _corrected = content(client)
      assert saved(ctx).transfer_sequence == 10 and saved(ctx).outbox == nil
    end

    client = click(client, 61, 0, "pickup", &(&1.carried == ItemStack.new("oak_planks", 4)))
    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))
    _client = content(client, &(&1.container == 0 and &1.carried == nil))
    assert :sys.get_state(pid).table_menu == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {fresh, fresh_pid} = login(ctx)
    fresh = open(fresh, ctx)
    assert Enum.all?(Enum.take(fresh.inventory.items, 27), &(&1 == nil))

    assert :sys.get_state(fresh_pid).inventory.slots == %{
             36 => ItemStack.new("diamond", 3),
             44 => ItemStack.new("oak_planks", 8)
           }

    assert saved(ctx).transfer_sequence == 11 and saved(ctx).outbox == nil
    assert stored(ctx).entries[ctx.position].slots == Tuple.duplicate(nil, 27)
    assert stored(ctx).receipts[ctx.uuid].sequence == 11
    assert stored(ctx).sequence == 8
  end

  test "lid blocking denies initial open but does not close an already valid view", ctx do
    seed(ctx)
    {x, y, z} = ctx.position
    above = {x, y + 1, z}
    :ok = World.set_block(above, Data.block("stone"))
    {client, pid} = login(ctx)
    use_chest(client, ctx)
    {_, client} = Client.await(client, :play, "block_changed_ack")
    assert :sys.get_state(pid).table_menu == nil
    :ok = World.set_block(above, 0)
    client = open(client, ctx)
    :ok = World.set_block(above, Data.block("stone"))

    wait(fn ->
      state = :sys.get_state(pid)
      state.table_job == nil and state.table_menu != nil
    end)

    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))
    _client = content(client, &(&1.container == 0))
    use_chest(client, ctx)
    {_, _client} = Client.await(client, :play, "block_changed_ack")
    assert :sys.get_state(pid).table_menu == nil
  end

  test "a chest-shaped block without an owned container cannot open", ctx do
    seed(ctx, :survival, false)
    {client, pid} = login(ctx)
    use_chest(client, ctx)
    {_, _client} = Client.await(client, :play, "block_changed_ack")
    assert :sys.get_state(pid).table_menu == nil
    refute File.exists?(Store.container_path(ctx.base, ctx.key))
  end

  test "close waits for a prepared action and conflicting inventory input cannot interleave",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      send_click(client, 54)
      wait(fn -> match?(%{stage: :delivery}, :sys.get_state(pid).recovery) end)
      assert saved(ctx).outbox.kind == :container and saved(ctx).transfer_sequence == 1
      assert saved(ctx).inventory.slots == %{36 => ItemStack.new("oak_planks", 8)}

      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      Client.send_packet(client, :play, "set_carried_item", <<2::signed-16>>)
      Client.send_packet(client, :play, "container_click", <<0, 0, 36::signed-16, 0, 0, 0, 0>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
      {_, client} = Client.await(client, :play, "system_chat")
      assert :sys.get_state(pid).table_menu == nil and :sys.get_state(pid).table_closing
      assert :sys.get_state(pid).inventory.selected == 0
      assert stored(ctx).receipts[ctx.uuid].sequence == 0
      :sys.resume(writer)
      _client = content(client, &(&1.container == 0 and &1.carried == nil))

      wait(fn ->
        :sys.get_state(pid).recovery == nil and not :sys.get_state(pid).table_closing
      end)

      assert :sys.get_state(pid).inventory.slots == %{36 => ItemStack.new("oak_planks", 8)}
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      assert stored(ctx).receipts[ctx.uuid].sequence == 1
      assert elem(stored(ctx).entries[ctx.position].slots, 0) == ItemStack.new("diamond", 3)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "two live players racing one chest conserve its contents and refresh both views", ctx do
    seed(ctx)
    other_name = "ChestB#{rem(System.unique_integer([:positive]), 1_000_000_000)}"
    other = %{ctx | name: other_name, uuid: Connection.offline_uuid(other_name)}
    {:ok, bytes} = PlayerSnapshot.encode(other.uuid, saved(ctx))
    File.write!(PlayerStore.path(ctx.base, other.uuid), bytes)
    {first, first_pid} = login(ctx)
    {second, second_pid} = login(other)
    first = open(first, ctx)
    second = open(second, other)
    for client <- [first, second], do: send_click(client, 0)

    for client <- [first, second],
        do: Client.send_packet(client, :play, "chat_command", Wire.string("stats"))

    {_, first} = Client.await(first, :play, "system_chat")
    {_, second} = Client.await(second, :play, "system_chat")

    wait(fn ->
      Enum.all?([first_pid, second_pid], fn pid ->
        state = :sys.get_state(pid)

        state.recovery == nil and state.table_job == nil and state.table_queued == 0 and
          state.table_menu != nil and elem(state.table_menu.view.slots, 0) == nil
      end)
    end)

    carried = for pid <- [first_pid, second_pid], do: :sys.get_state(pid).inventory.carried
    assert Enum.sort(carried) == Enum.sort([nil, ItemStack.new("diamond", 3)])
    assert elem(stored(ctx).entries[ctx.position].slots, 0) == nil
    assert stored(ctx).sequence == 3
    assert saved(ctx).outbox == nil and saved(other).outbox == nil

    for {client, actor} <- [{first, ctx}, {second, other}] do
      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      _client = content(client, &(&1.container == 0 and &1.carried == nil))
      assert saved(actor).outbox == nil
    end
  end

  test "closing a paused candidate retires its late result without allocating a source sequence",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    writer = :sys.get_state(pid).player_store
    :sys.suspend(writer)

    try do
      send_click(client, 54)

      wait(fn ->
        match?(%{kind: :container, stage: :candidate}, :sys.get_state(pid).table_job)
      end)

      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      _client = content(client, &(&1.container == 0))
      assert :sys.get_state(pid).table_job == nil and :sys.get_state(pid).recovery == nil
      :sys.resume(writer)
      # A writer call is a barrier after its already-queued candidate cast.
      _state = :sys.get_state(writer)
      assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
      assert :sys.get_state(pid).inventory.slots == %{36 => ItemStack.new("oak_planks", 8)}
      assert stored(ctx).receipts[ctx.uuid].sequence == 0
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "destination owner loss after source preparation recovers one decision and closes the old view",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    {:ok, {region, _} = owner} = World.existing_owner(ctx.key)
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      send_click(client, 54, 0, "quick_move")

      wait(fn ->
        match?(%{stage: :delivery}, :sys.get_state(pid).recovery) and
          match?(
            %{kind: :container, phase: :writing},
            :sys.get_state(region).resource.item_pending
          )
      end)

      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox.kind == :container
      monitor = Process.monitor(region)
      Process.exit(region, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^region, :killed}
      :sys.resume(writer)
      _client = content(client, &(&1.container == 0 and &1.carried == nil))

      wait(fn ->
        :sys.get_state(pid).recovery == nil and not :sys.get_state(pid).table_closing
      end)

      {:ok, replacement} = World.existing_owner(ctx.key)
      assert replacement != owner
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      assert :sys.get_state(pid).inventory.slots == %{}
      assert elem(stored(ctx).entries[ctx.position].slots, 1) == ItemStack.new("oak_planks", 8)
      assert stored(ctx).receipts[ctx.uuid].sequence == 1
      assert World.item_snapshot(ctx.key) == %{}
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "hand and secondary dispatch preserve native precedence, including spectator viewing",
       ctx do
    for {mode, hand, shift, expected} <- [
          {:survival, 0, false, true},
          {:survival, 1, false, false},
          {:survival, 0, true, false},
          {:spectator, 1, true, true}
        ] do
      seed(ctx, mode)
      {client, pid} = login(ctx)
      Client.send_packet(client, :play, "player_input", <<if(shift, do: 32, else: 0)>>)

      if expected do
        client = open(client, ctx, hand)

        if mode == :spectator do
          send_click(client, 0)
          client = content(client)
          assert hd(client.inventory.items) == ItemStack.new("diamond", 3)
          assert client.inventory.carried == nil
          assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
        end
      else
        use_chest(client, ctx, hand)
        {_, _client} = Client.await(client, :play, "block_changed_ack")
        assert :sys.get_state(pid).table_menu == nil
      end

      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    end
  end

  test "removal, relocation and replacement owner retire their view without changing stored items",
       ctx do
    seed(ctx, :survival, true, nil)
    before = File.read!(Store.container_path(ctx.base, ctx.key))
    {client, pid} = login(ctx)
    client = open(client, ctx)
    :ok = World.set_block(ctx.position, 0)
    client = content(client, &(&1.container == 0))
    assert :sys.get_state(pid).table_menu == nil
    :ok = World.set_block(ctx.position, @chest)
    client = open(client, ctx)
    client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 20})
    assert :sys.get_state(pid).table_menu == nil
    client = Client.teleport(client, pid, ctx.pose)
    client = open(client, ctx)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :ok = Region.flush(region)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    {:ok, _} = World.owner(ctx.key)
    _client = content(client, &(&1.container == 0))
    assert :sys.get_state(pid).table_menu == nil
    assert File.read!(Store.container_path(ctx.base, ctx.key)) == before
    assert :sys.get_state(pid).inventory.slots == %{36 => ItemStack.new("oak_planks", 8)}
  end
end
