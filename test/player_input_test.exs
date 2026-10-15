defmodule Valimc.PlayerInputTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Valimc.PlayerInput, as: Input
  alias Valimc.Protocol.{Data, Packets, Wire}

  test "all byte values retain seven booleans and ignore the reserved high bit" do
    for byte <- 0..255 do
      assert {:ok, input} = Input.receive_input(Input.loaded(%Input{}), <<byte>>)
      assert input.buttons == (byte &&& 127)
      assert input.shared_flags == if((byte &&& 32) != 0, do: 2, else: 0)

      for {key, mask} <- [
            forward: 1,
            backward: 2,
            left: 4,
            right: 8,
            jump: 16,
            shift: 32,
            sprint: 64
          ],
          do: assert(Input.pressed?(input, key) == ((byte &&& mask) != 0))
    end
  end

  test "load completion retains intent but does not replay pre-load flags or commands" do
    assert {:ok, input} = Input.receive_input(%Input{}, <<96>>)
    assert {:ok, input} = Input.receive_command(input, command(1))
    assert input.buttons == 96
    assert input.shared_flags == 0
    input = Input.loaded(input)
    assert Input.loaded?(input)
    assert input.shared_flags == 0
    assert Input.loaded(input) == input
    assert {:ok, input} = Input.receive_input(input, <<96>>)
    assert input.shared_flags == 2
  end

  test "fallback opens on tick 60 and never synthesizes an input update" do
    {:ok, input} = Input.receive_input(%Input{}, <<32>>)
    input = Enum.reduce(1..59, input, fn _, acc -> Input.tick(acc) end)
    refute Input.loaded?(input)
    assert {:ok, unchanged} = Input.receive_command(input, command(1))
    assert unchanged == input
    input = Input.tick(input)
    assert Input.loaded?(input)
    assert Input.tick(input) == input
    assert input.shared_flags == 0
    {:ok, input} = Input.receive_command(input, command(1))
    assert input.shared_flags == 8
  end

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

  test "metadata-only changes and unchanged quantized movement do not fabricate movement" do
    player = player()
    previous = Packets.view(player)
    assert Packets.move_entity(player, previous) == []
    player = put_in(player.input.shared_flags, 10)
    assert [packet] = Packets.move_entity(player, previous)
    assert metadata(packet) == {300, 10}
    assert Packets.move_entity(player, Packets.view(player)) == []

    moved = %{player | x: 0.75}
    assert [movement, flags] = Packets.move_entity(moved, previous)
    assert elem(movement, 0) == Data.id(:play, :clientbound, "move_entity_pos_rot")
    assert metadata(flags) == {300, 10}
  end

  test "tracking recreation initializes unchanged metadata and tuple removal stays valid" do
    player = put_in(player().input.shared_flags, 10)
    previous = Packets.view(player)

    assert [removed, added, flags, pose, environment] =
             Packets.move_entity(%{player | z: 10.0}, previous)

    assert removed == Packets.remove_entity(previous)
    assert elem(added, 0) == Data.id(:play, :clientbound, "add_entity")
    assert metadata(flags) == {300, 10}
    assert pose == Packets.player_pose(player)
    assert environment == Packets.player_environment(player)
    assert Packets.remove_info(player) == Packets.remove_info(previous)
  end

  defp command(action, id \\ 300, data \\ 0),
    do: IO.iodata_to_binary([Wire.varint(id), Wire.varint(action), Wire.varint(data)])

  defp player,
    do: %{
      entity_id: 300,
      uuid: <<0::128>>,
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      input: %Input{}
    }

  defp metadata({id, bytes}) do
    assert id == Data.id(:play, :clientbound, "set_entity_data")
    {entity, <<0, 0, flags, 255>>} = Wire.take_varint(IO.iodata_to_binary(bytes))
    {entity, flags}
  end
end
