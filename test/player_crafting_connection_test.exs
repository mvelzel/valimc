defmodule Valimc.PlayerCraftingConnectionTest do
  use ExUnit.Case, async: false
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

    %{base: base, name: name, uuid: uuid, pose: pose}
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

  test "mixed ingredient clicks derive sticks; incompatible/full cursor and result throw refuse",
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
    client = client |> click(2) |> click(0, 0, "throw")
    assert client.inventory.carried == nil
    assert Enum.at(client.inventory.items, 2) == ItemStack.new("oak_planks", 2)
    client = click(client, 0)
    assert client.inventory.carried == ItemStack.new("stick", 4)
    assert Enum.at(client.inventory.items, 2) == ItemStack.new("oak_planks")
    assert Enum.at(client.inventory.items, 4) == ItemStack.new("spruce_planks")
    assert Inventory.get(:sys.get_state(owner).inventory, 0) == nil
    assert :sys.get_state(owner).recovery == nil
  end

  test "result shift/swap packets consume inputs and correct partial-overflow predictions", ctx do
    seed(ctx, %{36 => ItemStack.new("oak_log", 17)})
    {client, owner} = login(ctx)
    client = client |> click(36) |> click(1) |> click(0, 0, "quick_move")
    assert Enum.at(client.inventory.items, 44) == ItemStack.new("oak_planks", 64)
    assert Enum.at(client.inventory.items, 43) == ItemStack.new("oak_planks", 4)
    assert hd(client.inventory.items) == nil and Enum.at(client.inventory.items, 1) == nil
    inv = %Inventory{slots: Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})}

    inv = %{
      inv
      | slots:
          Map.merge(inv.slots, %{
            1 => ItemStack.new("oak_log", 2),
            44 => ItemStack.new("oak_planks", 62)
          })
    }

    :sys.replace_state(owner, fn state -> %{state | inventory: inv} end)
    client = click(client, 0, 0, "quick_move")
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log", 2)
    assert Enum.at(client.inventory.items, 44) == ItemStack.new("oak_planks", 62)

    :sys.replace_state(owner, fn state ->
      %{state | inventory: %{state.inventory | slots: Map.delete(state.inventory.slots, 36)}}
    end)

    client = click(client, 0, 0, "swap")
    assert Enum.at(client.inventory.items, 1) == ItemStack.new("oak_log")
    assert Enum.at(client.inventory.items, 36) == ItemStack.new("oak_planks", 4)
    assert :sys.get_state(owner).recovery == nil
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
end
