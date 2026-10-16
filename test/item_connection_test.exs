defmodule Valimc.ItemConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.World
  alias Valimc.World.Region
  defp name, do: "Item" <> Integer.to_string(System.unique_integer([:positive]))

  defp await_entity(client, packet, id) do
    {body, client} = Client.await(client, :play, packet)
    {entity, _} = Wire.take_varint(body)
    if entity == id, do: {body, client}, else: await_entity(client, packet, id)
  end

  defp await_removal(client, id) do
    {body, client} = Client.await(client, :play, "remove_entities")
    {count, body} = Wire.take_varint(body)
    {ids, <<>>} = Enum.map_reduce(1..count, body, fn _, bytes -> Wire.take_varint(bytes) end)
    if id in ids, do: client, else: await_removal(client, id)
  end

  defp assert_stack(client, id, stack) do
    {body, client} = await_entity(client, "set_entity_data", id)
    {^id, <<5, 8, 1, 8, 7, body::binary>>} = Wire.take_varint(body)
    assert {:ok, ^stack, <<255>>} = ItemStack.take(body)
    client
  end

  test "world items replicate current stacks to late joiners, visibility changes and owner loss" do
    username = name()
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    key = {0, 0}
    {:ok, {pid, epoch} = owner} = World.item_owner(key)
    stone = ItemStack.new("stone", 7)
    egg = ItemStack.new("egg", 3)
    {:ok, {^pid, ^epoch, id, 1} = first} = Region.create_item(owner, stone, {0.5, 64.5, 0.5})
    on_exit(fn -> if Process.alive?(pid), do: Region.remove_item({pid, epoch, id, 2}) end)
    {_spawn, client} = await_entity(client, "add_entity", id)
    client = assert_stack(client, id, stone)
    {:ok, second} = Region.replace_item(first, egg)
    client = assert_stack(client, id, egg)

    {_, late} = Client.login(name())
    on_exit(fn -> Client.close(late) end)
    {_, late} = await_entity(late, "add_entity", id)
    _late = assert_stack(late, id, egg)

    client =
      Client.teleport(client, player.pid, %{x: 160.5, y: 64.0, z: 160.5, yaw: 0.0, pitch: 0.0})
      |> await_removal(id)

    client = Client.teleport(client, player.pid, %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0})
    {_, client} = await_entity(client, "add_entity", id)
    client = assert_stack(client, id, egg)
    assert :ok = Region.remove_item(second)
    client = await_removal(client, id)
    {:ok, {^pid, ^epoch, another, 1}} = Region.create_item(owner, stone, {0.5, 64.5, 0.5})
    {_, client} = await_entity(client, "add_entity", another)
    client = assert_stack(client, another, stone)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    client = await_removal(client, another)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {body, _} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "schedulers") != :nomatch
  end

  test "accepted item steps reach the existing observer and fresh tracking at the latest position" do
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {:ok, {pid, epoch} = owner} = World.item_owner({0, 0})
    stack = ItemStack.new("stone", 3)
    {:ok, {^pid, ^epoch, id, 1}} = Region.create_item(owner, stack, {4.5, 64.5, 4.5})
    {_spawn, client} = await_entity(client, "add_entity", id)
    client = assert_stack(client, id, stack)

    step = %{
      id: id,
      revision: 1,
      position: {6.5, 64.5, 4.5},
      motion: %Valimc.ItemMotionState{velocity: {0.1, 0.0, 0.0}, no_gravity: true}
    }

    assert {:ok, [handle]} = Region.advance_items(owner, [step])
    on_exit(fn -> if Process.alive?(pid), do: Region.remove_item(handle) end)
    {body, client} = await_entity(client, "entity_position_sync", id)

    assert {^id, <<0, 6.5::float-64, 64.5::float-64, 4.5::float-64, 0::64, 0>>} =
             Wire.take_varint(body)

    {_velocity, _client} = await_entity(client, "set_entity_motion", id)
    {_, late} = Client.login(name())
    on_exit(fn -> Client.close(late) end)
    {body, late} = await_entity(late, "add_entity", id)
    {^id, <<_uuid::128, body::binary>>} = Wire.take_varint(body)
    {_, <<6.5::float-64, 64.5::float-64, 4.5::float-64, _::binary>>} = Wire.take_varint(body)
    _late = assert_stack(late, id, stack)
  end
end
