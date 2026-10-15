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

  defp move(client, x, z) do
    Client.send_packet(client, :play, "client_tick_end", <<>>)

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<x::float-64, 64.0::float-64, z::float-64, 1>>
    )
  end

  test "world items replicate current stacks to late joiners, visibility changes and owner loss" do
    {_, client} = Client.login(name())
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
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
    client = move(client, 160.5, 160.5) |> await_removal(id)
    client = move(client, 0.5, 0.5)
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
end
