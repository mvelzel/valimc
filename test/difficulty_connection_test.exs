defmodule Valimc.DifficultyConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.World.Clock

  defp login(name) do
    client = Client.begin_login(name)
    {_uuid, client} = Client.configure_session(client, name)
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    Client.await(client, :play, "change_difficulty")
  end

  defp no_changes_until_time(client) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)
    refute name == "change_difficulty"

    if name == "set_time",
      do: client,
      else: no_changes_until_time(Client.auto_reply(client, :play, name, body))
  end

  test "initial/current difficulty reaches multiple clients; peer edits cannot mutate world settings" do
    {<<1, 0>>, first} = login("DifficultyProbe")
    {<<1, 0>>, second} = login("DifficultyPeer")

    on_exit(fn ->
      Client.close(first)
      Client.close(second)
      Clock.configure({:difficulty_locked, false})
      Clock.configure({:difficulty, 1})
    end)

    assert :ok = Clock.configure({:difficulty_locked, true})
    {<<1, 1>>, first} = Client.await(first, :play, "change_difficulty")
    {<<1, 1>>, second} = Client.await(second, :play, "change_difficulty")
    assert :ok = Clock.configure({:difficulty, 3, true})
    {<<3, 1>>, first} = Client.await(first, :play, "change_difficulty")
    {<<3, 1>>, second} = Client.await(second, :play, "change_difficulty")
    first = Client.send_packet(first, :play, "change_difficulty", <<0>>)
    first = Client.send_packet(first, :play, "lock_difficulty", <<0>>)
    first = Client.send_packet(first, :play, "chat_command", Wire.string("stats"))
    {_body, first} = Client.await(first, :play, "system_chat")
    assert Clock.snapshot().difficulty.level == 3 and Clock.snapshot().difficulty.locked
    _first = first |> no_changes_until_time() |> no_changes_until_time()
    Client.close(second)
    {<<3, 1>>, rejoined} = login("DifficultyPeer")
    Client.close(rejoined)
  end
end
