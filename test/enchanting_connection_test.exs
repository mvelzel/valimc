defmodule Valimc.EnchantingConnectionTest do
  @moduledoc """
  The enchanting table through a connection (VMC-038a): it opens, takes a
  sword and lapis, shows the seed's offers and enchants on a button; closing
  gives the inputs back.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Experience, GameMode, PlayerList}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-enchanting-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {71_000 + rem(nonce, 3_333) * 3, 958}
    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "Ench#{nonce}"
    uuid = Valimc.Data.UUID.offline(name)

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

  defp target(ctx), do: {floor(ctx.pose.x), 64, floor(ctx.pose.z) + 3}

  defp seed(ctx, slots) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        progression: %Valimc.Player.Progression{
          experience: Experience.set_levels(%Experience{}, 30)
        },
        enchantment_seed: 20_261_101
      })

    {:ok, bytes} =
      PlayerState.encode(ctx.uuid, PlayerState.capture(player, %Inventory{slots: slots}))

    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    :ok =
      Valimc.TestBlocks.set(
        target(ctx),
        Valimc.Protocol.Data.item_block(Valimc.Protocol.Data.item("enchanting_table"))
      )
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    owner = Enum.find(PlayerList.all(), &(&1.name == ctx.name)).pid
    on_exit(fn -> Client.close(client) end)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    Valimc.TestWait.until(fn ->
      Valimc.Player.Input.loaded?(Valimc.TestConn.state(owner).player.input)
    end)

    {client, owner}
  end

  defp send_click(client, slot, action) do
    Client.send_packet(client, :play, "container_click", [
      Wire.varint(client.inventory.container),
      <<0, slot::signed-16, 0::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<0, 0>>
    ])
  end

  test "an enchanting table enchants a sword for lapis and levels", ctx do
    seed(ctx, %{36 => ItemStack.new("diamond_sword"), 37 => ItemStack.new("lapis_lazuli", 5)})
    {client, pid} = login(ctx)

    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(0),
      Wire.position(target(ctx)),
      <<1, 0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
    ])

    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    assert {13, _title} = Wire.take_varint(body)
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)

    # Shift-clicks: the sword (hotbar 0, window 29) to the item slot, the
    # lapis (hotbar 1, window 30) to its own.
    send_click(%{client | inventory: %{client.inventory | container: id}}, 29, "quick_move")
    send_click(%{client | inventory: %{client.inventory | container: id}}, 30, "quick_move")

    Valimc.TestWait.until(fn ->
      match?(
        {%ItemStack{}, %ItemStack{count: 5}},
        Valimc.TestConn.state(pid).inventory.payments
      ) and Valimc.TestConn.state(pid).table_menu.offers != nil
    end)

    offers = Valimc.TestConn.state(pid).table_menu.offers
    {cost, _clue} = Enum.at(offers, 0)
    assert cost >= 1

    Client.send_packet(client, :play, "container_button_click", [Wire.varint(id), Wire.varint(0)])

    Valimc.TestWait.until(fn ->
      {item, _} = Valimc.TestConn.state(pid).inventory.payments
      map_size(ItemStack.component(item, "minecraft:enchantments") || %{}) > 0
    end)

    state = Valimc.TestConn.state(pid)
    assert {_, %ItemStack{count: 4}} = state.inventory.payments
    assert state.player.progression.experience.level == 29
    assert state.player.enchantment_seed != 20_261_101

    # Closing gives both back.
    Client.send_packet(client, :play, "container_close", Wire.varint(id))
    Valimc.TestWait.until(fn -> Valimc.TestConn.state(pid).inventory.payments == nil end)
    slots = Valimc.TestConn.state(pid).inventory.slots

    assert Enum.any?(slots, fn {_, s} ->
             s.item_id == ItemTypes.id("minecraft:diamond_sword") and
               map_size(ItemStack.component(s, "minecraft:enchantments") || %{}) > 0
           end)
  end
end
