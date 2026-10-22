defmodule Valimc.MalformedPacketConnectionTest do
  # Every play decoder ends only its sender's session on malformed input
  # (`Connection.guard_connection/2`); one healthy peer keeps responding throughout.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Protocol.{Enchantments, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  defp creative_component(component, raw) do
    [
      <<36::signed-16, 1>>,
      Wire.varint(ItemTypes.id("stone")),
      <<1, 0>>,
      Wire.varint(ItemTypes.component_id(component)),
      Wire.varint(byte_size(raw)),
      raw
    ]
  end

  # A syntactically complete chain that exceeds the NBT decoder's depth budget.
  defp deep_nbt, do: <<10>> <> :binary.copy(<<10, 0, 1, ?x>>, 33) <> :binary.copy(<<0>>, 34)

  defp cases do
    unbreaking = Enchantments.id("minecraft:unbreaking")

    [
      {"player_input", <<32, 0>>},
      {"player_command", <<1, 7, 0>>},
      {"player_loaded", <<1>>},
      {"client_tick_end", <<0>>},
      {"move_player_status_only", <<>>},
      {"client_information", <<1, ?a>>},
      {"container_close", <<0, 1>>},
      {"change_game_mode", <<1, 0>>},
      {"set_creative_mode_slot", <<36::16, 0, 99>>},
      {"set_creative_mode_slot", creative_component("custom_data", deep_nbt())},
      {"set_creative_mode_slot", creative_component("tooltip_display", <<0, 1, 122>>)},
      {"set_creative_mode_slot",
       creative_component("enchantments", <<1, unbreaking>> <> Wire.varint(-1))}
    ]
  end

  test "each malformed play packet disconnects only its sender" do
    {_, healthy} = login()

    for {packet, payload} <- cases() do
      {name, bad} = login()
      pid = Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == name)).pid
      ref = Process.monitor(pid)
      Client.send_packet(bad, :play, packet, payload)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000, packet
    end

    _healthy = Client.barrier(healthy)
    assert Process.alive?(Process.whereis(Valimc.Net.Listener))
  end

  defp login do
    name = "Bad" <> Integer.to_string(System.unique_integer([:positive]))
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    {name, client}
  end
end
