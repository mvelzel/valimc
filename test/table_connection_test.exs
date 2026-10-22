defmodule Valimc.TableConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Net.Connection
  alias Valimc.Player.{GameMode, PlayerList}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-table-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 3_333) * 3, 957}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "Menu#{nonce}"
    uuid = Connection.offline_uuid(name)

    on_exit(fn ->
      for player <- PlayerList.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Valimc.TestWorld.registered({x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base, name: name, uuid: uuid, pose: pose, key: key}
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, slots, mode \\ :survival) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.Player.Abilities.for_mode(mode)
      })

    {:ok, bytes} =
      PlayerState.encode(ctx.uuid, PlayerState.capture(player, %Inventory{slots: slots}))

    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    :ok =
      Valimc.TestBlocks.set(
        target(ctx),
        Valimc.Protocol.Data.item_block(Valimc.Protocol.Data.item("crafting_table"))
      )
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    owner = Enum.find(PlayerList.all(), &(&1.name == ctx.name)).pid
    on_exit(fn -> Client.close(client) end)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.Player.Input.loaded?(Valimc.TestConn.state(owner).player.input) end)
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
    assert Valimc.TestConn.state(pid).inventory.slots[0] == nil
    client = click(client, 0, 4, "swap")
    assert hd(client.inventory.items) == nil
    assert Valimc.TestConn.state(pid).inventory.slots[40] == ItemStack.new("wooden_pickaxe")
    assert Valimc.TestConn.state(pid).inventory.slots[45] == ItemStack.new("leather", 5)
    Client.send_packet(client, :play, "container_close", Wire.varint(first))
    client = inventory_until(client, &(&1.container == 0))
    assert Valimc.TestConn.state(pid).inventory.table_inputs == nil
    client = open(client, ctx)
    assert client.inventory.container != first
    send_click(client, 41, 0, "pickup", first)
    client = inventory_until(client, &(&1.container != first))
    assert Valimc.TestConn.state(pid).table_menu.id == client.inventory.container
    assert Valimc.TestConn.state(pid).inventory.carried == nil
    Client.send_packet(client, :play, "container_close", <<99>>)
    _client = inventory_until(client, &(&1.container == 0))
    assert Valimc.TestConn.state(pid).table_menu == nil
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {fresh, pid} = login(ctx)
    assert fresh.inventory.container == 0
    assert Enum.at(fresh.inventory.items, 40) == ItemStack.new("wooden_pickaxe")
    assert Valimc.TestConn.state(pid).inventory.table_inputs == nil
  end

  test "a table bulk throw repeats in one click, before the clicks after it", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17), 37 => ItemStack.new("cobblestone")})
    {client, pid} = login(ctx)
    client = open(client, ctx) |> click(37) |> click(1)
    send_click(client, 0, 1, "throw")
    send_click(client, 38)

    wait(fn -> Valimc.TestConn.state(pid).inventory.carried == ItemStack.new("cobblestone") end)

    assert Valimc.TestConn.state(pid).inventory.table_inputs == Tuple.duplicate(nil, 9)
    assert length(records(ctx)) == 17
    assert Enum.all?(records(ctx), &(&1.stack == ItemStack.new("oak_planks", 4)))
  end

  defp records(ctx) do
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    Valimc.Entity.Store.records(Valimc.TestRegion.section(owner).entities.store)
  end
end
