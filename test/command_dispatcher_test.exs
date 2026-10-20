defmodule Valimc.CommandDispatcherTest do
  use ExUnit.Case, async: true
  # Parsing is pure; the commands oracle stage compares it with vanilla's dispatcher.
  alias Valimc.Command.{Error, Reader, Source, Text}

  defp parse(input, level \\ 4), do: Valimc.Commands.parse(input, Source.parse_only(level))

  test "operators parse vanilla commands; others do not see restricted ones" do
    assert {:ok, {Valimc.Commands.Players, :gamemode}, %{"gamemode" => :creative}, _} =
             parse("gamemode creative")

    assert {:error,
            %Error{message: {:compound, %{"translate" => {:string, "command.unknown.command"}}}}} =
             parse("gamemode creative", 0)

    assert {:ok, {Valimc.Commands.Chat, :help}, %{}, _} = parse("help", 0)
  end

  test "argument failures carry vanilla's cursor" do
    assert {:error, %Error{cursor: 16, input: "gamemode creativ"} = error} =
             parse("gamemode creativ")

    assert [_message, context] = Error.feedback(error, "gamemode creativ")
    assert inspect(context) =~ "command.context.here"
    assert {:error, %Error{cursor: 0}} = parse("gamemode survival @e")
  end

  test "graphs differ by permission level and always carry ValiMC's literals" do
    refute Valimc.Commands.graph_payload(0) == Valimc.Commands.graph_payload(4)
    assert :binary.match(Valimc.Commands.graph_payload(0), "gamemode") == :nomatch
    assert :binary.match(Valimc.Commands.graph_payload(4), "gamemode") != :nomatch
    assert :binary.match(Valimc.Commands.graph_payload(0), "stats") != :nomatch
  end

  test "the reader counts UTF-16 code units like Java" do
    reader = Reader.new("é😀x")
    assert reader.size == 4
    assert Reader.slice(reader, 3, 4) == "x"
    assert Text.literal("a") == {:compound, %{"text" => {:string, "a"}}}
  end

  test "server suggestions answer ask_server time markers and timelines" do
    source = Source.parse_only(4)
    assert {10, 0, markers} = Valimc.Command.Suggestions.suggest("/time set ", source)
    assert markers == ~w(minecraft:day minecraft:midnight minecraft:night minecraft:noon)

    assert {10, 1, ["minecraft:night", "minecraft:noon"]} =
             Valimc.Command.Suggestions.suggest("/time set n", source)

    assert {12, 11, ["minecraft:day"]} =
             Valimc.Command.Suggestions.suggest("/time query minecraft:d", source)

    assert {12, 0,
            [
              "gametime",
              "minecraft:day",
              "minecraft:early_game",
              "minecraft:moon",
              "minecraft:villager_schedule",
              "time"
            ]} =
             Valimc.Command.Suggestions.suggest("/time query ", source)

    assert {_, _, []} =
             Valimc.Command.Suggestions.suggest("/time of minecraft:the_end set ", source)

    assert {1, 4, ["time"]} = Valimc.Command.Suggestions.suggest("/time", source)
    assert Valimc.Command.Suggestions.matches_sub_str?("sch", "villager_schedule")
  end
end
