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
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
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

  defp records(ctx) do
    {:ok, {pid, _}} = Valimc.World.item_owner(ctx.key)
    Valimc.World.Items.records(Valimc.TestConn.state(pid).resource.items)
  end
end
