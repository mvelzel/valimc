defmodule Valimc.RconTest do
  use ExUnit.Case, async: false
  # RCON (VMC-010g): vanilla's packets, login and command output.
  @moduletag :tcp

  defp connect do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Valimc.Rcon.port(), [:binary, packet: :raw, active: false])

    socket
  end

  defp request(socket, id, type, text) do
    :ok =
      :gen_tcp.send(socket, [
        <<byte_size(text) + 10::little-32, id::little-signed-32, type::little-signed-32>>,
        text,
        <<0, 0>>
      ])
  end

  defp reply(socket) do
    {:ok, <<length::little-32>>} = :gen_tcp.recv(socket, 4, 2000)

    {:ok, <<id::little-signed-32, type::little-signed-32, rest::binary>>} =
      :gen_tcp.recv(socket, length, 2000)

    {id, type, binary_part(rest, 0, byte_size(rest) - 2)}
  end

  setup do
    start_supervised!({Valimc.Rcon, port: 0, password: "secret"})
    :ok
  end

  test "login, commands and their output" do
    socket = connect()
    request(socket, 7, 3, "wrong")
    assert reply(socket) == {-1, 2, ""}
    request(socket, 8, 2, "list")
    assert reply(socket) == {-1, 2, ""}

    request(socket, 9, 3, "secret")
    assert reply(socket) == {9, 2, ""}
    request(socket, 10, 2, "list")
    assert {10, 0, "There are 0 of a max of " <> _} = reply(socket)
    request(socket, 11, 2, "/save-on")
    assert reply(socket) == {11, 0, "Saving is already turned on"}
    request(socket, 12, 2, "nonsense")
    assert {12, 0, "Unknown or incomplete command. See below for error" <> rest} = reply(socket)
    assert rest =~ "nonsense<--[HERE]"
    request(socket, 13, 5, "")
    assert reply(socket) == {13, 0, "Unknown request 5"}
    :gen_tcp.close(socket)
  end

  test "an oversized packet ends the connection" do
    socket = connect()
    request(socket, 1, 3, String.duplicate("x", 1500))
    assert {:error, :closed} = :gen_tcp.recv(socket, 4, 2000)
  end

  test "an idle client is closed, so idle sockets cannot hold every slot" do
    previous = Valimc.config(:rcon_idle_ms)
    Application.put_env(:valimc, :rcon_idle_ms, 200)
    on_exit(fn -> Application.put_env(:valimc, :rcon_idle_ms, previous) end)
    socket = connect()
    assert {:error, :closed} = :gen_tcp.recv(socket, 4, 5000)
  end

  test "a command whose owner exits answers command.failed and the client goes on" do
    owner = Process.whereis(Valimc.World.Stopwatches)
    :sys.suspend(owner)
    on_exit(fn -> if Process.alive?(owner), do: :sys.resume(owner) end)
    socket = connect()
    request(socket, 1, 3, "secret")
    assert reply(socket) == {1, 2, ""}
    request(socket, 2, 2, "stopwatch create minecraft:rcon_held")
    {:ok, <<length::little-32>>} = :gen_tcp.recv(socket, 4, 15_000)

    {:ok, <<2::little-signed-32, 0::little-32, text::binary>>} =
      :gen_tcp.recv(socket, length, 2000)

    assert text =~ "An unexpected error occurred while trying to execute that command"
    :sys.resume(owner)
    request(socket, 3, 2, "stopwatch remove minecraft:rcon_held")
    assert {3, 0, _} = reply(socket)
  end
end
