defmodule Valimc.Commands do
  @moduledoc """
  The command catalog (VMC-053): vanilla's command tree pruned to the executable
  paths below, plus ValiMC's own `/stats` and `/spawn`. Graphs, parsing and
  dispatch all come from this one immutable tree; commands run in the player's
  connection process.

  A handler is `{module, function}` called with the parsed arguments and the
  `Valimc.Command.Source`; it returns `{result, state}` or throws a command
  syntax error (`Valimc.Command.Error`).
  """
  alias Valimc.Command.{Arguments, Dispatcher, Error, Feedback, Source, Tree}
  alias Valimc.Commands.{Chat, Players, Preview}

  @handlers %{
    ["help"] => {Chat, :help},
    ["help", "command"] => {Chat, :help_command},
    ["gamemode", "gamemode"] => {Players, :gamemode},
    ["gamemode", "gamemode", "target"] => {Players, :gamemode},
    ["defaultgamemode", "gamemode"] => {Players, :default_gamemode}
  }

  @extras [{"stats", {Preview, :stats}}, {"spawn", {Preview, :spawn}}]

  @root Tree.build(@handlers, @extras)
  @nodes Tree.by_path(@root)
  @graphs Map.new(0..4, &{&1, Tree.graph(@root, &1)})

  for {path, node} <- @nodes, node.type == :argument, node.parser not in Arguments.supported() do
    raise "Command node #{Enum.join(path, " ")} needs unsupported parser #{node.parser}"
  end

  for {path, _} <- @handlers, not match?(%{command: {_, _}}, @nodes[path]) do
    raise "Command handler for #{Enum.join(path, " ")} names no executable vanilla node"
  end

  def root, do: @root
  def node!(path), do: Map.fetch!(@nodes, path)
  def handlers, do: @handlers

  @doc "The commands packet payload for a player at permission `level`."
  def graph_payload(level), do: Map.fetch!(@graphs, level)

  @doc "Parses `input` for `source`: `{:ok, handler, arguments, context}` or `{:error, error}`."
  def parse(input, source) do
    parse = Dispatcher.parse(@root, input, source)

    case Dispatcher.finish(parse) do
      {:ok, last, context} ->
        arguments = Map.new(last.arguments, fn {name, {value, _range}} -> {name, value} end)
        {:ok, last.command, arguments, context}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Executes a chat command (without `/`) as the connection's player."
  def execute(state, input) do
    source = Source.player(state)

    case parse(input, source) do
      {:ok, {module, function}, arguments, _context} ->
        run(source, module, function, arguments)

      {:error, error} ->
        for message <- Error.feedback(error, input), do: Feedback.success(source, message, false)
        state
    end
  end

  defp run(source, module, function, arguments) do
    {_result, state} = apply(module, function, [arguments, source])
    state
  catch
    {:command_syntax, %Error{} = error} ->
      Feedback.failure(source, error.message)
      source.state
  end
end
