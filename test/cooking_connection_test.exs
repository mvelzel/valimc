defmodule Valimc.CookingConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.World.{Containers, Region}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])

    base =
      Path.join(System.tmp_dir!(), "valimc-cooking-view-#{System.os_time(:nanosecond)}-#{nonce}")

    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {72_000 + rem(nonce, 10_000), 961}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "CookV#{rem(nonce, 1_000_000_000)}"
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

  defp seed(ctx, kind, mode \\ :survival, cooking \\ %Valimc.Cooking{}, recipes \\ %{}) do
    input = ItemStack.new(if(kind == :smoker, do: "cod", else: "raw_iron"), 3)

    inventory = %Inventory{
      slots: %{
        36 => input,
        37 => ItemStack.new("coal", 7),
        38 => ItemStack.new("bucket", 15),
        45 => ItemStack.new("stone", 2)
      }
    }

    seed_player(ctx, mode, inventory)

    {:ok, containers, entry} =
      Containers.create_cooking(%Containers{}, ctx.key, ctx.position, kind)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, ctx.position, entry.revision, cooking, recipes)

    {:ok, containers, _} = Valimc.World.ContainerTransfers.reserve(containers, ctx.uuid)
    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    {:ok, block} = Valimc.Physics.CookingBlocks.placement(kind, 0.0)
    block = if cooking.burn_left > 0, do: block - 1, else: block
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{ctx.position => block})

    :ok = World.set_block(ctx.position, block)
  end

  defp seed_player(ctx, mode, inventory) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.PlayerInput.loaded?(Valimc.TestConn.state(pid).player.input) end)

    on_exit(fn ->
      Client.close(client)

      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)
    end)

    {client, pid}
  end

  defp use_menu(client, ctx, hand \\ 0) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(hand),
      Wire.position(ctx.position),
      # Target the occupied underside so secondary-use negatives cannot place
      # the held item above the processor.
      <<0, 0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
    ])
  end

  defp content(client, predicate \\ fn _ -> true end) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    if predicate.(client.inventory), do: client, else: content(client, predicate)
  end

  defp open(client, ctx, kind) do
    use_menu(client, ctx)
    {_, client} = Client.await(client, :play, "block_changed_ack")
    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    {:ok, type} = Valimc.CookingMenu.type(kind)
    assert {^type, _} = Wire.take_varint(body)
    client = content(client)
    assert client.inventory.container == id and length(client.inventory.items) == 39

    {client, properties} =
      Enum.reduce(0..3, {client, []}, fn index, {client, values} ->
        {body, client} = Client.await(client, :play, "container_set_data")
        {^id, <<^index::signed-16, value::signed-16>>} = Wire.take_varint(body)
        {client, values ++ [value]}
      end)

    {client, properties}
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

  defp saved(ctx) do
    {:ok, snapshot} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    snapshot
  end

  defp stored(ctx) do
    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    containers
  end

  defp close(client, pid) do
    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))
    client = content(client, &(&1.container == 0 and &1.carried == nil))

    wait(fn ->
      Valimc.TestConn.state(pid).table_menu == nil and
        not Valimc.TestConn.state(pid).table_closing
    end)

    client
  end

  defp subscribed(pid) do
    wait(fn ->
      state = Valimc.TestConn.state(pid)
      state.table_menu && state.table_menu.subscribed && state.table_job == nil
    end)
  end

  test "invalid fuel/output deposits and stale menu ids do not allocate an intent", ctx do
    seed(ctx, :furnace)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :furnace)
    client = click(client, 30, 0, "pickup", &(&1.carried == ItemStack.new("raw_iron", 3)))
    before = stored(ctx)

    for slot <- [1, 2] do
      send_click(client, slot)
      _client = content(client)
      assert Valimc.TestConn.state(pid).inventory.carried == ItemStack.new("raw_iron", 3)
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      assert stored(ctx) == before
    end

    _client = click(client, 30, 0, "pickup", &(&1.carried == nil))
    old_id = client.inventory.container
    client = close(client, pid)
    send_click(client, 0, 0, "pickup", old_id)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _client} = Client.await(client, :play, "system_chat")
    assert Valimc.TestConn.state(pid).table_menu == nil
    assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
    assert stored(ctx).entries[ctx.position].cooking.slots == {nil, nil, nil}
  end

  test "fuel bucket accepts one and closes with the exact remainder", ctx do
    seed(ctx, :furnace)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :furnace)
    client = click(client, 32, 0, "pickup", &(&1.carried == ItemStack.new("bucket", 15)))

    client =
      click(client, 1, 0, "pickup", fn inventory ->
        Enum.at(inventory.items, 1) == ItemStack.new("bucket") and
          inventory.carried == ItemStack.new("bucket", 14)
      end)

    send_click(client, 1)
    client = content(client)
    assert Valimc.TestConn.state(pid).inventory.carried == ItemStack.new("bucket", 14)
    assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
    _client = close(client, pid)
    assert stored(ctx).entries[ctx.position].cooking.slots == {nil, ItemStack.new("bucket"), nil}
    slots = Valimc.TestConn.state(pid).inventory.slots

    assert Enum.sum(
             for {_, stack} <- slots, stack.item_id == Data.item("bucket"), do: stack.count
           ) ==
             14
  end

  for {kind, recipe, item} <- [
        {:furnace, "minecraft:gold_ingot_from_smelting_raw_gold", "gold_ingot"},
        {:smoker, "minecraft:cooked_beef_from_smoking", "cooked_beef"},
        {:blast_furnace, "minecraft:gold_ingot_from_blasting_raw_gold", "gold_ingot"}
      ],
      action <- ["pickup", "quick_move"] do
    @tag xp_kind: kind, xp_recipe: recipe, xp_item: item, xp_action: action
    test "#{kind} #{action} output clears uses, learns its recipe and collects durable XP", ctx do
      %{xp_kind: kind, xp_recipe: recipe, xp_item: item, xp_action: action} = ctx
      cooking = %Valimc.Cooking{slots: {nil, nil, ItemStack.new(item, 3)}}
      seed(ctx, kind, :survival, cooking, %{recipe => 3})
      {client, pid} = login(ctx)
      {client, _} = open(client, ctx, kind)
      send_click(client, 2, 0, action)

      wait(fn ->
        cs = stored(ctx)

        cs.entries[ctx.position].recipes == %{} and map_size(cs.pending_awards) == 1 and
          Valimc.TestConn.state(pid).recovery == nil
      end)

      [{_, decision}] = Map.to_list(stored(ctx).pending_awards)
      amount = decision.award.experience
      assert amount in 1..3
      wait(fn -> Valimc.TestConn.state(pid).player.progression.experience.total == amount end)
      player = Valimc.TestConn.state(pid)
      assert MapSet.member?(player.player.progression.recipes, recipe)
      assert elem(stored(ctx).entries[ctx.position].cooking.slots, 2) == nil

      if action == "pickup",
        do: assert(player.inventory.carried == ItemStack.new(item, 3)),
        else:
          assert(Enum.any?(player.inventory.slots, fn {_, s} -> s == ItemStack.new(item, 3) end))

      assert stored(ctx).orb_consumption.revision > 0
      assert saved(ctx).outbox == nil
      assert saved(ctx).progression.experience.total == amount
      assert saved(ctx).transfer_sequence == stored(ctx).receipts[ctx.uuid].sequence
      # An empty result cannot clear credit or create another decision.
      client = content(client, fn inv -> Enum.at(inv.items, 2) == nil end)
      send_click(client, 2, 0, action)
      _client = close(client, pid)
      assert map_size(stored(ctx).pending_awards) == 1
    end
  end

  test "shared cooking views refresh exactly once and spectators cannot exchange", ctx do
    cooking = %Valimc.Cooking{slots: {ItemStack.new("raw_iron", 2), nil, nil}}
    seed(ctx, :furnace, :survival, cooking)
    name = "CookB#{rem(System.unique_integer([:positive]), 1_000_000_000)}"
    other = %{ctx | name: name, uuid: Connection.offline_uuid(name)}
    seed_player(other, :spectator, %Inventory{})
    {first, first_pid} = login(ctx)
    {second, second_pid} = login(other)
    {first, _} = open(first, ctx, :furnace)
    {second, _} = open(second, other, :furnace)
    for pid <- [first_pid, second_pid], do: subscribed(pid)
    send_click(second, 0)
    second = content(second)
    assert saved(other).transfer_sequence == 0 and saved(other).outbox == nil
    assert :sys.get_state(second_pid).inventory.carried == nil
    first = click(first, 0, 0, "pickup", &(&1.carried == ItemStack.new("raw_iron", 2)))
    second = content(second, &(Enum.take(&1.items, 3) == [nil, nil, nil]))
    assert :sys.get_state(second_pid).table_menu.view.cooking.slots == {nil, nil, nil}
    assert :sys.get_state(first_pid).chest_lids.positions == %{}
    assert :sys.get_state(second_pid).chest_lids.positions == %{}
    {:ok, {region, _}} = World.existing_owner(ctx.key)

    assert Valimc.World.ContainerViewers.open_count(
             :sys.get_state(region).resource.container_viewers,
             ctx.position
           ) == 0

    _first = close(first, first_pid)
    _second = close(second, second_pid)
    wait(fn -> :sys.get_state(region).resource.container_viewers.views == %{} end)
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
  end

  test "relocation and owner loss close cooking views without changing stored items", ctx do
    seed(ctx, :smoker)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :smoker)
    before = stored(ctx)
    client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 20})
    assert Valimc.TestConn.state(pid).table_menu == nil
    client = Client.teleport(client, pid, ctx.pose)
    {client, _} = open(client, ctx, :smoker)
    subscribed(pid)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :ok = Region.flush(region)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    _client = content(client, &(&1.container == 0))
    assert Valimc.TestConn.state(pid).table_menu == nil
    assert stored(ctx) == before
    assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
  end

  test "destination loss after cooking preparation recovers one decision and retires the view",
       ctx do
    seed(ctx, :blast_furnace)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :blast_furnace)
    {:ok, {region, _} = owner} = World.existing_owner(ctx.key)
    writer = :sys.get_state(region).resource.store
    :sys.suspend(writer)

    try do
      send_click(client, 30, 0, "quick_move")

      wait(fn ->
        match?(%{stage: :delivery}, Valimc.TestConn.state(pid).recovery) and
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
        Valimc.TestConn.state(pid).recovery == nil and
          not Valimc.TestConn.state(pid).table_closing
      end)

      {:ok, replacement} = World.existing_owner(ctx.key)
      assert replacement != owner
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil

      assert stored(ctx).entries[ctx.position].cooking.slots ==
               {ItemStack.new("raw_iron", 3), nil, nil}

      assert stored(ctx).receipts[ctx.uuid].sequence == 1
      assert World.item_snapshot(ctx.key) == %{}
      refute Map.has_key?(Valimc.TestConn.state(pid).inventory.slots, 36)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "two players racing one cooking input conserve its quantity and refresh both views", ctx do
    cooking = %Valimc.Cooking{slots: {ItemStack.new("cod", 2), nil, nil}}
    seed(ctx, :smoker, :survival, cooking)
    name = "CookB#{rem(System.unique_integer([:positive]), 1_000_000_000)}"
    other = %{ctx | name: name, uuid: Connection.offline_uuid(name)}
    seed_player(other, :survival, %Inventory{})
    {first, first_pid} = login(ctx)
    {second, second_pid} = login(other)
    {first, _} = open(first, ctx, :smoker)
    {second, _} = open(second, other, :smoker)
    for client <- [first, second], do: send_click(client, 0)

    for pid <- [first_pid, second_pid] do
      wait(fn ->
        state = Valimc.TestConn.state(pid)

        state.recovery == nil and state.table_job == nil and state.table_queued == 0 and
          state.table_menu != nil and state.table_menu.view.cooking.slots == {nil, nil, nil}
      end)
    end

    carried = for pid <- [first_pid, second_pid], do: Valimc.TestConn.state(pid).inventory.carried
    assert Enum.sort(carried) == Enum.sort([nil, ItemStack.new("cod", 2)])
    assert stored(ctx).entries[ctx.position].cooking.slots == {nil, nil, nil}
    assert stored(ctx).sequence == 3
    assert saved(ctx).outbox == nil and saved(other).outbox == nil
    _first = close(first, first_pid)
    _second = close(second, second_pid)
  end

  test "closing a pending cooking candidate retires its late result without an intent", ctx do
    seed(ctx, :furnace)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :furnace)
    writer = Valimc.TestConn.state(pid).player_store
    :sys.suspend(writer)

    try do
      send_click(client, 30, 0, "quick_move")

      wait(fn ->
        match?(%{kind: :container, stage: :candidate}, Valimc.TestConn.state(pid).table_job)
      end)

      Client.send_packet(
        client,
        :play,
        "container_close",
        Wire.varint(client.inventory.container)
      )

      _client = content(client, &(&1.container == 0))
      :sys.resume(writer)
      _barrier = :sys.get_state(writer)

      assert Valimc.TestConn.state(pid).table_job == nil and
               Valimc.TestConn.state(pid).recovery == nil

      assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
      assert stored(ctx).entries[ctx.position].cooking.slots == {nil, nil, nil}
      assert stored(ctx).receipts[ctx.uuid].sequence == 0
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "live input edits preserve count-only progress and reset cleared input without overwriting heat",
       ctx do
    cooking = %Valimc.Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal"), nil},
      burn_left: 67,
      burn_total: 1600,
      progress: 49,
      total: 100,
      speed: 2.0
    }

    seed(ctx, :blast_furnace, :survival, cooking)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :blast_furnace)
    client = click(client, 0, 1, "pickup", &(&1.carried == ItemStack.new("raw_iron")))
    changed = stored(ctx).entries[ctx.position].cooking
    assert changed == %{cooking | slots: {ItemStack.new("raw_iron"), ItemStack.new("coal"), nil}}

    client =
      click(client, 0, 0, "quick_move", fn inventory ->
        Enum.at(inventory.items, 0) == nil and inventory.carried == ItemStack.new("raw_iron")
      end)

    changed = stored(ctx).entries[ctx.position].cooking

    assert changed == %{
             cooking
             | slots: {nil, ItemStack.new("coal"), nil},
               progress: 0,
               total: 200
           }

    _client = close(client, pid)
    assert saved(ctx).transfer_sequence == 2 and saved(ctx).outbox == nil
  end

  for kind <- [:furnace, :smoker, :blast_furnace] do
    test "#{kind} menu exposes native progress and ignores solid blocks above without chest opener events",
         ctx do
      kind = unquote(kind)

      cooking = %Valimc.Cooking{
        slots:
          {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), ItemStack.new("iron_ingot")},
        burn_left: 67,
        burn_total: 1600,
        progress: 49,
        total: 100,
        speed: 2.0
      }

      seed(ctx, kind, :survival, cooking)
      {x, y, z} = ctx.position
      :ok = World.set_block({x, y + 1, z}, Data.block("stone"))
      {client, pid} = login(ctx)
      {client, properties} = open(client, ctx, kind)
      assert properties == [67, 1600, 49, 100]
      assert Enum.take(client.inventory.items, 3) == Tuple.to_list(cooking.slots)

      assert Valimc.TestConn.state(pid).table_menu.kind == :cooking and
               Valimc.TestConn.state(pid).inventory.table_inputs == nil

      {:ok, {region, _}} = World.existing_owner(ctx.key)
      wait(fn -> map_size(:sys.get_state(region).resource.container_viewers.views) == 1 end)
      viewers = :sys.get_state(region).resource.container_viewers
      assert Valimc.World.ContainerViewers.open_count(viewers, ctx.position) == 0
      refute Valimc.TestConn.state(pid).table_menu.opener
      _client = close(client, pid)
      wait(fn -> :sys.get_state(region).resource.container_viewers.views == %{} end)
      assert stored(ctx).entries[ctx.position].cooking == cooking
    end
  end

  test "owned timer observations refresh properties without invalidating content or accepting old sessions",
       ctx do
    cooking = %Valimc.Cooking{burn_left: 67, burn_total: 1600, progress: 10, total: 200}
    seed(ctx, :furnace, :survival, cooking)
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, :furnace)
    subscribed(pid)
    # Opening precedes the asynchronous subscription snapshot. Consume that
    # second initial observation before testing the later timer notification.
    client = content(client)

    client =
      Enum.reduce(0..3, client, fn index, client ->
        {body, client} = Client.await(client, :play, "container_set_data")
        {_, <<^index::signed-16, _::signed-16>>} = Wire.take_varint(body)
        client
      end)

    menu = Valimc.TestConn.state(pid).table_menu
    assert menu.view.generation == 0
    observed_inventory = client.inventory
    {region, _} = owner = menu.owner
    position = ctx.position

    :sys.replace_state(region, fn state ->
      resource = state.resource
      entry = resource.containers.entries[position]
      entry = %{entry | cooking: %{entry.cooking | progress: 11}}

      containers = %{
        resource.containers
        | entries: Map.put(resource.containers.entries, position, entry)
      }

      {viewers, [_]} =
        Valimc.World.ContainerViewers.progressed(resource.container_viewers, position, 1)

      %{
        state
        | resource: %{
            resource
            | containers: containers,
              container_viewers: viewers,
              cooking_progress: %{position => 1}
          }
      }
    end)

    Connection.deliver(pid, {:container_progress, owner, menu.view_ref, position, 1})

    client =
      Enum.reduce(0..3, client, fn index, client ->
        {body, client} = Client.await(client, :play, "container_set_data")
        {_, <<^index::signed-16, value::signed-16>>} = Wire.take_varint(body)
        assert value == Enum.at([67, 1600, 11, 200], index)
        client
      end)

    wait(fn -> Valimc.TestConn.state(pid).table_menu.view.generation == 1 end)
    assert client.inventory == observed_inventory
    assert Valimc.TestConn.state(pid).inventory.state_id == observed_inventory.state_id
    assert Valimc.TestConn.state(pid).table_menu.view.revision == menu.view.revision
    assert Valimc.TestConn.state(pid).table_menu.view.cooking.progress == 11
    assert saved(ctx).transfer_sequence == 0 and saved(ctx).outbox == nil
    refute :sys.get_state(region).resource.container_viewers.views[pid].progress_pending

    for {candidate_owner, ref, generation} <- [
          {{region, make_ref()}, menu.view_ref, 2},
          {owner, make_ref(), 2},
          {owner, menu.view_ref, 1}
        ],
        do:
          Connection.deliver(
            pid,
            {:container_progress, candidate_owner, ref, position, generation}
          )

    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await(client, :play, "system_chat")
    assert Valimc.TestConn.state(pid).table_menu.view.generation == 1
    assert Valimc.TestConn.state(pid).table_job == nil
    _client = close(client, pid)
  end

  for kind <- [:furnace, :smoker, :blast_furnace], mode <- [:survival, :creative] do
    input_name = if kind == :smoker, do: "cod", else: "raw_iron"

    test "#{mode} #{kind} exchanges seal once through pickup, shift, offhand and reconnect",
         ctx do
      kind = unquote(kind)
      input = ItemStack.new(unquote(input_name), 3)
      seed(ctx, kind, unquote(mode))
      {client, pid} = login(ctx)
      {client, _} = open(client, ctx, kind)
      client = click(client, 30, 0, "pickup", &(&1.carried == input))

      client =
        click(
          client,
          0,
          1,
          "pickup",
          &(Enum.at(&1.items, 0) == %{input | count: 1} and &1.carried == %{input | count: 2})
        )

      client =
        click(client, 0, 0, "pickup", &(Enum.at(&1.items, 0) == input and &1.carried == nil))

      client =
        click(client, 31, 0, "quick_move", &(Enum.at(&1.items, 1) == ItemStack.new("coal", 7)))

      client = click(client, 0, 40, "swap", &(Enum.at(&1.items, 0) == ItemStack.new("stone", 2)))
      assert Valimc.TestConn.state(pid).inventory.slots[45] == input
      client = click(client, 0, 40, "swap", &(Enum.at(&1.items, 0) == input))

      client =
        click(
          client,
          1,
          0,
          "quick_move",
          &(Enum.at(&1.items, 1) == nil and Enum.at(&1.items, 3) == ItemStack.new("coal", 7))
        )

      client =
        click(
          client,
          0,
          0,
          "quick_move",
          &(Enum.at(&1.items, 0) == nil and Enum.at(&1.items, 4) == input)
        )

      assert saved(ctx).transfer_sequence == 8 and saved(ctx).outbox == nil
      assert stored(ctx).entries[ctx.position].cooking.slots == {nil, nil, nil}
      assert stored(ctx).receipts[ctx.uuid].sequence == 8 and stored(ctx).sequence == 9

      expected = %{
        9 => ItemStack.new("coal", 7),
        10 => input,
        38 => ItemStack.new("bucket", 15),
        45 => ItemStack.new("stone", 2)
      }

      assert Valimc.TestConn.state(pid).inventory.slots == expected
      client = close(client, pid)
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      {fresh, fresh_pid} = login(ctx)
      {fresh, _} = open(fresh, ctx, kind)
      assert Enum.take(fresh.inventory.items, 3) == [nil, nil, nil]
      assert :sys.get_state(fresh_pid).inventory.slots == expected
      assert saved(ctx).transfer_sequence == 8 and saved(ctx).outbox == nil
      _fresh = close(fresh, fresh_pid)
    end
  end
end
