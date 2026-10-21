defmodule Valimc.TooltipConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{ItemTypes, Wire}
  defp name, do: "Tip" <> Integer.to_string(System.unique_integer([:positive]))

  test "malformed/unknown tooltip set input rejects only its owner while a peer responds" do
    {_, healthy} = Client.login(name())
    on_exit(fn -> Client.close(healthy) end)

    for raw <- [<<0, 1, 122>>, <<0, 1>>, <<>>, IO.iodata_to_binary([<<0>>, Wire.varint(1025)])] do
      username = name()
      {_, bad} = Client.login(username)
      on_exit(fn -> Client.close(bad) end)
      bad = Client.load_world(bad)
      player = Enum.find(Valimc.Players.all(), &(&1.name == username))
      ref = Process.monitor(player.pid)

      Client.send_packet(bad, :play, "set_creative_mode_slot", [
        <<36::signed-16, 1>>,
        Wire.varint(ItemTypes.id("stone")),
        <<1, 0>>,
        Wire.varint(ItemTypes.component_id("tooltip_display")),
        Wire.varint(byte_size(raw)),
        raw
      ])

      {body, _} = Client.await(bad, :play, "disconnect")
      assert :binary.match(body, "invalid creative item") != :nomatch
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
      {_, _} = Client.await_stats(healthy)
    end
  end
end
