defmodule Valimc.CookingConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.World.Containers
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])

    base =
      Path.join(System.tmp_dir!(), "valimc-cooking-view-#{System.os_time(:nanosecond)}-#{nonce}")

    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {72_000 + rem(nonce, 3_333) * 3, 961}
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
            {Valimc.RegionRegistry, Valimc.RegionSupervisor, key}
          ],
          {pid, _} <- Registry.lookup(registry, identity),
          do: DynamicSupervisor.terminate_child(supervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_players(base)
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

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

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

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    {:ok, block} = Valimc.CookingBlocks.placement(kind, 0.0)
    block = if cooking.burn_left > 0, do: block - 1, else: block
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{ctx.position => block})

    :ok = Valimc.TestBlocks.set(ctx.position, block)
  end

  defp seed_player(ctx, mode, inventory) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
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
    {:ok, type} = Valimc.Menu.cooking_type(kind)
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

  defp send_click(client, slot, button, action) do
    Client.send_packet(client, :play, "container_click", [
      Wire.varint(client.inventory.container),
      <<0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<1, slot::signed-16, 0, 0>>
    ])
  end

  defp click(client, slot, button, action, expected) do
    send_click(client, slot, button, action)
    content(client, expected)
  end

  # The orb entities the region holds, durably (VMC-077h).
  defp orbs(ctx) do
    with {:ok, {pid, _}} <- Valimc.TestWorld.existing_owner(ctx.key),
         do: Valimc.World.Region.flush(pid)

    case Valimc.TestDisk.read(ctx.base, ctx.key, :items) do
      nil -> []
      saved -> Enum.filter(saved.records, &(&1.kind == :orb))
    end
  end

  # The containers as their owner's frames hold them, once it wrote them.
  defp stored(ctx) do
    with {:ok, {pid, _}} <- Valimc.TestWorld.existing_owner(ctx.key),
         do: Valimc.World.Region.flush(pid)

    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    containers
  end

  defp close(client, pid) do
    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))
    client = content(client, &(&1.container == 0 and &1.carried == nil))

    wait(fn -> Valimc.TestConn.state(pid).table_menu == nil end)

    client
  end

  defp subscribed(pid) do
    wait(fn ->
      state = Valimc.TestConn.state(pid)
      state.table_menu != nil
    end)
  end

  @tag xp_kind: :furnace,
       xp_recipe: "minecraft:gold_ingot_from_smelting_raw_gold",
       xp_item: "gold_ingot",
       xp_action: "pickup"
  test "output clears uses, learns its recipe and collects durable XP", ctx do
    %{xp_kind: kind, xp_recipe: recipe, xp_item: item, xp_action: action} = ctx
    cooking = %Valimc.Cooking{slots: {nil, nil, ItemStack.new(item, 3)}}
    seed(ctx, kind, :survival, cooking, %{recipe => 3})
    {client, pid} = login(ctx)
    {client, _} = open(client, ctx, kind)
    send_click(client, 2, 0, action)

    wait(fn -> stored(ctx).entries[ctx.position].recipes == %{} end)

    # The withdrawal's orbs spawn at the player, who collects every unit.
    wait(fn ->
      Valimc.TestConn.state(pid).player.progression.experience.total > 0 and orbs(ctx) == []
    end)

    amount = Valimc.TestConn.state(pid).player.progression.experience.total
    assert amount in 1..3
    player = Valimc.TestConn.state(pid)
    assert MapSet.member?(player.player.progression.recipes, recipe)
    assert elem(stored(ctx).entries[ctx.position].cooking.slots, 2) == nil

    if action == "pickup",
      do: assert(player.inventory.carried == ItemStack.new(item, 3)),
      else:
        assert(Enum.any?(player.inventory.slots, fn {_, s} -> s == ItemStack.new(item, 3) end))

    # An empty result cannot clear credit or create another decision.
    client = content(client, fn inv -> Enum.at(inv.items, 2) == nil end)
    send_click(client, 2, 0, action)
    _client = close(client, pid)
    assert orbs(ctx) == []
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

    Valimc.TestRegion.replace_section(owner, fn resource ->
      entry = resource.containers.entries[position]
      entry = %{entry | cooking: %{entry.cooking | progress: 11}}

      containers = %{
        resource.containers
        | entries: Map.put(resource.containers.entries, position, entry)
      }

      {viewers, [_]} =
        Valimc.World.ContainerViewers.progressed(resource.container_viewers, position, 1)

      %{
        resource
        | containers: containers,
          container_viewers: viewers,
          cooking_progress: %{position => 1}
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
    refute Valimc.TestRegion.section(owner).container_viewers.views[pid].progress_pending

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
    {_, client} = Client.await_stats(client)
    assert Valimc.TestConn.state(pid).table_menu.view.generation == 1
    _client = close(client, pid)
  end

  test "exchanges seal once through pickup, shift, offhand and reconnect", ctx do
    kind = :furnace
    input = ItemStack.new("raw_iron", 3)
    seed(ctx, kind)
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

    assert stored(ctx).entries[ctx.position].cooking.slots == {nil, nil, nil}
    assert stored(ctx).sequence == 9

    expected = %{
      9 => ItemStack.new("coal", 7),
      10 => input,
      38 => ItemStack.new("bucket", 15),
      45 => ItemStack.new("stone", 2)
    }

    assert Valimc.TestConn.state(pid).inventory.slots == expected
    client = close(client, pid)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {fresh, fresh_pid} = login(ctx)
    {fresh, _} = open(fresh, ctx, kind)
    assert Enum.take(fresh.inventory.items, 3) == [nil, nil, nil]
    assert Valimc.TestConn.state(fresh_pid).inventory.slots == expected
    _fresh = close(fresh, fresh_pid)
  end
end
