defmodule Valimc.ChestConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Player.{GameMode, PlayerList}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.World.Containers
  alias Valimc.TestClient, as: Client
  @chest hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])

  setup do
    nonce = System.unique_integer([:positive])

    base =
      Path.join(System.tmp_dir!(), "valimc-chest-view-#{System.os_time(:nanosecond)}-#{nonce}")

    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {72_000 + rem(nonce, 3_333) * 3, 961}
    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "ChestV#{rem(nonce, 1_000_000_000)}"
    uuid = Valimc.Data.UUID.offline(name)

    on_exit(fn ->
      for player <- PlayerList.all(),
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

  defp seed(ctx, mode \\ :survival, present \\ true, stock \\ ItemStack.new("diamond", 3)) do
    inventory = %Inventory{slots: %{36 => ItemStack.new("oak_planks", 8)}}

    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.Player.Abilities.for_mode(mode)
      })

    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    # A live owner keeps its loaded region; durable fixtures only seed a cold one.
    unless match?({:ok, _}, Valimc.TestWorld.existing_owner(ctx.key)) do
      if present do
        {:ok, containers, entry} = Containers.create(%Containers{}, ctx.key, ctx.position, 3)
        slots = put_elem(entry.slots, 0, stock)
        {:ok, containers, _} = Containers.replace(containers, ctx.position, entry.revision, slots)
        {:ok, bytes} = Containers.encode(ctx.key, containers)
        Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
      end

      Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{ctx.position => @chest})
    end

    :ok = Valimc.TestBlocks.set(ctx.position, @chest)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(PlayerList.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.Player.Input.loaded?(Valimc.TestConn.state(pid).player.input) end)

    on_exit(fn ->
      Client.close(client)

      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)
    end)

    {client, pid}
  end

  defp use_chest(client, ctx, hand) do
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
    pid = Enum.find(PlayerList.all(), &(&1.name == ctx.name)).pid
    assert Valimc.TestConn.state(pid).table_menu != nil
    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    assert id in 1..127
    assert {2, _} = Wire.take_varint(body)
    client = content(client)
    assert client.inventory.container == id and length(client.inventory.items) == 63
    client
  end

  defp send_click(client, slot, button, action, id \\ nil) do
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
      PlayerState.decode(File.read!(Valimc.Player.Storage.path(ctx.base, ctx.uuid)), ctx.uuid)

    snapshot
  end

  # The containers as their owner's frames hold them, once it wrote them.
  defp stored(ctx) do
    with {:ok, {pid, _}} <- Valimc.TestWorld.existing_owner(ctx.key),
         do: Valimc.World.Region.flush(pid)

    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    containers
  end

  test "live pickup/split/merge/shift/number/offhand exchanges seal once and reconnect exactly",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    client = open(client, ctx)
    assert hd(client.inventory.items) == ItemStack.new("diamond", 3)
    assert Enum.at(client.inventory.items, 54) == ItemStack.new("oak_planks", 8)
    assert Valimc.TestConn.state(pid).inventory.table_inputs == nil
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

    assert {:error, :occupied_container} = Valimc.TestBlocks.set(ctx.position, 0)

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
    assert Valimc.TestConn.state(pid).inventory.slots[45] == ItemStack.new("oak_planks", 8)
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

    for {action, id} <- [{"throw", client.inventory.container}, {"pickup", 99}] do
      send_click(client, 54, 0, action, id)
      _corrected = content(client)
    end

    client = click(client, 61, 0, "pickup", &(&1.carried == ItemStack.new("oak_planks", 4)))
    Client.send_packet(client, :play, "container_close", Wire.varint(client.inventory.container))
    _client = content(client, &(&1.container == 0 and &1.carried == nil))
    assert Valimc.TestConn.state(pid).table_menu == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {fresh, fresh_pid} = login(ctx)
    fresh = open(fresh, ctx)
    assert Enum.all?(Enum.take(fresh.inventory.items, 27), &(&1 == nil))

    assert Valimc.TestConn.state(fresh_pid).inventory.slots == %{
             36 => ItemStack.new("diamond", 3),
             44 => ItemStack.new("oak_planks", 8)
           }

    assert stored(ctx).entries[ctx.position].slots == Tuple.duplicate(nil, 27)
    assert stored(ctx).sequence == 8
  end

  defp viewer_state(ctx) do
    {:ok, owner} = Valimc.TestWorld.existing_owner(ctx.key)
    Valimc.TestRegion.section(owner).container_viewers
  end

  defp subscribed(pid) do
    wait(fn ->
      state = Valimc.TestConn.state(pid)
      state.table_menu != nil
    end)
  end

  defp second_actor(ctx, mode \\ :survival) do
    name = "ChestB#{rem(System.unique_integer([:positive]), 1_000_000_000)}"
    other = %{ctx | name: name, uuid: Valimc.Data.UUID.offline(name)}

    snapshot = %{saved(ctx) | game_mode: GameMode.new(mode)}

    {:ok, bytes} = PlayerState.encode(other.uuid, snapshot)
    File.write!(Valimc.Player.Storage.path(ctx.base, other.uuid), bytes)
    other
  end

  test "first/last viewers share one sound; intermediate and spectator views are silent; removal never replays a close sound",
       ctx do
    seed(ctx, :survival, true, nil)
    {first, first_pid} = login(ctx)
    other = second_actor(ctx)
    {second, second_pid} = login(other)
    spectator = second_actor(ctx, :spectator)
    {spectator_client, spectator_pid} = login(spectator)
    Valimc.TestWorld.subscribe(MapSet.new([ctx.key]), MapSet.new())
    {:ok, owner} = Valimc.TestWorld.existing_owner(ctx.key)
    position = ctx.position

    first = open(first, ctx)
    subscribed(first_pid)
    assert_receive {:event, {:chest_lid, ^owner, ^position, true, _lid, sound}}
    assert is_binary(sound)

    assert {:ok, _id, expected, <<>>} =
             Wire.next_frame(sound, 2_097_152, Valimc.TestConn.state(first_pid).threshold)

    assert {^expected, second} = Client.await(second, :play, "sound")
    assert {^expected, spectator_client} = Client.await(spectator_client, :play, "sound")
    second = open(second, other)
    subscribed(second_pid)
    spectator_client = open(spectator_client, spectator)
    subscribed(spectator_pid)
    refute_receive {:event, {:chest_lid, _, _, _, _, _}}, 20

    Client.send_packet(first, :play, "container_close", Wire.varint(first.inventory.container))
    first = content(first, &(&1.container == 0))
    assert Valimc.World.ContainerViewers.open_count(viewer_state(ctx), position) == 1
    refute_receive {:event, {:chest_lid, _, _, _, _, _}}, 20
    Client.send_packet(second, :play, "container_close", Wire.varint(second.inventory.container))
    _second = content(second, &(&1.container == 0))
    assert_receive {:event, {:chest_lid, ^owner, ^position, false, _lid, sound}}
    assert is_binary(sound)

    Client.send_packet(
      spectator_client,
      :play,
      "container_close",
      Wire.varint(spectator_client.inventory.container)
    )

    _spectator_client = content(spectator_client, &(&1.container == 0))
    refute_receive {:event, {:chest_lid, _, _, _, _, _}}, 20

    _first = open(first, ctx)
    subscribed(first_pid)
    assert_receive {:event, {:chest_lid, ^owner, ^position, true, _, sound}}
    assert is_binary(sound)
    assert :ok = Valimc.TestBlocks.remove(position)
    assert_receive {:event, {:chest_lid, ^owner, ^position, false, _, nil}}
    wait(fn -> Valimc.TestConn.state(first_pid).table_menu == nil end)
  end
end
