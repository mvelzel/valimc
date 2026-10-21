defmodule Valimc.PlaceConnectionTest do
  use ExUnit.Case, async: false
  # `/place` over sockets in a flat world (VMC-053): templates, features and
  # jigsaws through the region owners; structures need noise terrain.
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire

  defp name(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp command(client, input, key) do
    Client.send_packet(client, :play, "chat_command", Wire.string(input))
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, key) != :nomatch, "#{input}: #{inspect(body)}"
    client
  end

  test "templates, features and jigsaws change the world; structures refuse in flat worlds" do
    {_, client} = Client.login(name("Place"))
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    air = Valimc.Registry.Blocks.default_state("air")

    client =
      command(
        client,
        "place template minecraft:igloo/top 8 64 8",
        "commands.place.template.success"
      )

    placed =
      for x <- 8..14, y <- 64..68, z <- 8..15, Valimc.World.get_block({x, y, z}) != air, do: 1

    assert length(placed) > 20

    client =
      command(client, "place template minecraft:nope 8 64 8", "commands.place.template.invalid")

    client =
      command(client, "place feature minecraft:oak 20 64 4", "commands.place.feature.success")

    assert Valimc.World.get_block({20, 64, 4}) == Valimc.Registry.Blocks.default_state("oak_log")
    client = command(client, "place structure minecraft:igloo", "not supported yet")

    client =
      command(
        client,
        "place jigsaw minecraft:nope minecraft:bottom 2",
        "commands.place.jigsaw.invalid"
      )

    _client =
      command(client, "place structure minecraft:nope", "commands.place.structure.invalid")
  end
end
