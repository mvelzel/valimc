defmodule Valimc.PlayerInputTest do
  use ExUnit.Case, async: true
  alias Valimc.Player.Input, as: Input
  alias Valimc.Protocol.Wire

  test "commands use current ordinals and affect only their sender regardless of declared ID/data" do
    input = Input.loaded(%Input{})
    {:ok, input} = Input.receive_input(input, <<32>>)
    {:ok, input} = Input.receive_command(input, command(1, -1, -2_147_483_648))
    assert input.shared_flags == 10
    {:ok, input} = Input.receive_input(input, <<64>>)
    assert input.shared_flags == 8
    {:ok, input} = Input.receive_command(input, command(2, 0, 2_147_483_647))
    assert input.shared_flags == 0
    assert Input.pressed?(input, :sprint)

    for action <- [0, 3, 4, 5, 6],
        do: assert(Input.receive_command(input, command(action)) == {:ok, input})
  end

  test "truncated, oversized and trailing payloads are rejected" do
    for body <- [<<>>, <<1, 2>>, :binary.copy(<<0>>, 100)],
        do: assert(Input.receive_input(%Input{}, body) == {:error, :invalid_player_input})

    for body <- [
          <<>>,
          <<1>>,
          <<1, 1>>,
          <<1, 7, 0>>,
          <<1, 1, 0, 0>>,
          command(-1),
          <<255, 255, 255, 255, 16>>,
          :binary.copy(<<128>>, 16)
        ],
        do: assert(Input.receive_command(%Input{}, body) == {:error, :invalid_player_command})
  end

  defp command(action, id \\ 300, data \\ 0),
    do: IO.iodata_to_binary([Wire.varint(id), Wire.varint(action), Wire.varint(data)])
end
