defmodule Valimc.PlayerCraftingConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerStore}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-crafting-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 3_333) * 3, 850}
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
          {pid, _} <- Valimc.TestWorld.registered({x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base, name: name, uuid: uuid, pose: pose, key: key}
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, slots) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(:survival),
        abilities: Valimc.PlayerAbilities.for_mode(:survival)
      })

    {:ok, bytes} =
      PlayerState.encode(ctx.uuid, PlayerState.capture(player, %Inventory{slots: slots}))

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

  test "live survival result packets craft one recipe, close physical items and reconnect exactly",
       ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 2)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1)
    assert hd(client.inventory.items) == ItemStack.new("oak_planks", 4)
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log", 2)
    assert Inventory.get(Valimc.TestConn.state(owner).inventory, 0) == nil
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
    inv = Valimc.TestConn.state(owner).inventory
    assert inv.slots == %{36 => ItemStack.new("oak_planks", 8)}

    {:ok, saved} =
      PlayerState.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved.inventory.slots == inv.slots
  end
end
