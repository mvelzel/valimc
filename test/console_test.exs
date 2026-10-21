defmodule Valimc.ConsoleTest do
  use ExUnit.Case, async: false
  # The server console's commands and English output (VMC-010f).
  import ExUnit.CaptureLog
  alias Valimc.Commands

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  defp console(line), do: capture_log([level: :info], fn -> Commands.execute_console(line) end)

  test "commands run at level 4 and print English text" do
    assert console("save-off") =~ "Automatic saving is now disabled"
    assert console("/save-off") =~ "Saving is already turned off"
    assert console("save-on") =~ "Automatic saving is now enabled"
    assert console("version") =~ "Server version info:"

    assert console("forceload query") =~
             "No force loaded chunks were found in minecraft:overworld"
  end

  test "errors and commands that need a player" do
    assert console("nonsense") =~ "Unknown or incomplete command. See below for error"
    assert console("nonsense") =~ "nonsense<--[HERE]"
    assert console("gamemode creative") =~ "A player is required to run this command here"
    assert console("kill @s") =~ "No entity was found"
  end
end
