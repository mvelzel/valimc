defmodule Valimc.Commands do
  @moduledoc """
  The command catalog (VMC-053, VMC-077o): vanilla's command tree pruned to the
  commands `registry/0` names, plus ValiMC's own `/stats` and `/spawn`. The tree
  and the commands packets are built once from `priv/commands/tree.json` at
  start; graphs, parsing and dispatch all come from it.

  A command runs in its own process (VMC-077a): a player's as a command job of
  its connection (`Valimc.Session.Commands`), the console's in the console
  reader and RCON's in its client. Owner calls happen there; players are
  changed through their connections (`Valimc.Commands.Remote`). A handler is
  `{module, function}` called with the parsed arguments and the
  `Valimc.Commands.Source`; it returns its result or throws a command syntax
  error (`Valimc.Text.Error`). Any other exception or exit is vanilla's
  `command.failed`, and the source's session lives on.
  """
  require Logger
  alias Valimc.Commands.Parser.{Arguments, Dispatcher, Tree}
  alias Valimc.Text.Error
  alias Valimc.Commands.{Feedback, Source}
  alias Valimc.Text

  @doc """
  The catalog (VMC-077o): one registration per top-level command, its handler
  `{module, function}` and, optionally, the executable vanilla paths below it
  that ValiMC does not run yet (`except:`) or the only ones it runs (`only:`),
  and `suggest: true` when its module answers its `ask_server` nodes
  (`suggest(path, arguments, source)`: `{:names, names}` or `{:resources, ids}`).
  A handler gets the parsed arguments with the literals of the parsed path
  after the command's name (`:literals`, in order) and picks its mode from
  them. The table is data read at runtime, so this module depends on no
  handler at compile time.
  """
  def registry do
    alias Valimc.Commands, as: C

    %{
      "ban" => {C.Operators, :ban},
      "ban-ip" => {C.Operators, :ban_ip},
      "banlist" => {C.Operators, :banlist},
      "clear" => {C.Players, :clear},
      "clone" => {C.Blocks, :clone},
      "defaultgamemode" => {C.Players, :default_gamemode},
      "deop" => {C.Operators, :deop, suggest: true},
      "dialog" => {C.Effects, :dialog},
      "difficulty" => {C.World, :difficulty},
      "effect" => {C.Players, :effect},
      "experience" => {C.Players, :experience},
      "fill" =>
        {C.World, :fill,
         except: [
           ~w(fill from to block destroy),
           ~w(fill from to block replace filter destroy)
         ]},
      "fillbiome" => {C.Blocks, :fillbiome},
      "forceload" => {C.Blocks, :forceload},
      "gamemode" => {C.Players, :gamemode},
      "gamerule" => {C.World, :gamerule, only: C.World.gamerule_paths()},
      "give" => {C.Players, :give},
      "help" => {C.Chat, :help},
      "kick" => {C.Admin, :kick},
      "kill" => {C.Players, :kill},
      "list" => {C.Chat, :list},
      "locate" => {C.Locate, :locate, except: [~w(locate poi poi)]},
      "me" => {C.Chat, :me},
      "msg" => {C.Chat, :msg},
      "op" => {C.Operators, :op, suggest: true},
      "pardon" => {C.Operators, :pardon, suggest: true},
      "pardon-ip" => {C.Operators, :pardon_ip, suggest: true},
      "particle" => {C.Effects, :particle},
      "place" => {C.Place, :place, suggest: true},
      "playsound" => {C.Effects, :playsound},
      "posteffect" => {C.PostEffects, :posteffect},
      "save-all" => {C.Server, :save_all},
      "save-off" => {C.Server, :save_off},
      "save-on" => {C.Server, :save_on},
      "say" => {C.Chat, :say},
      "seed" => {C.World, :seed},
      "setblock" => {C.World, :setblock, except: [~w(setblock pos block destroy)]},
      "setidletimeout" => {C.Server, :setidletimeout},
      "setworldspawn" => {C.World, :setworldspawn},
      "stop" => {C.Admin, :stop},
      "stopsound" => {C.Effects, :stopsound},
      "stopwatch" => {C.Timers, :stopwatch, suggest: true},
      "teleport" => {C.Players, :teleport},
      "tellraw" => {C.Text, :tellraw},
      "tick" => {C.Timers, :tick},
      "time" => {C.World, :time, suggest: true},
      "title" => {C.Text, :title},
      "transfer" => {C.Operators, :transfer},
      "version" => {C.Admin, :version},
      "weather" => {C.World, :weather},
      "whitelist" => {C.Operators, :whitelist, suggest: true},
      "worldborder" => {C.WorldBorder, :worldborder},
      # ValiMC's own, beside vanilla's tree.
      "stats" => {C.Preview, :stats, own: true},
      "spawn" => {C.Preview, :spawn, own: true}
    }
  end

  @doc "Build the tree and the commands packets once (application start; tools on first use)."
  def init! do
    root = Tree.build(Map.new(registry(), fn {name, entry} -> {name, options(entry)} end))
    nodes = Tree.by_path(root)

    for {path, node} <- nodes,
        node.type == :argument,
        node.parser not in Arguments.supported() do
      raise "Command node #{Enum.join(path, " ")} needs unsupported parser #{node.parser}"
    end

    # Every registration runs something, and an `only:` path is executable.
    for {name, entry} <- registry() do
      {module, function} = handler(name)
      Code.ensure_loaded!(module)

      unless function_exported?(module, function, 2) and
               Enum.any?(nodes, &(elem(&1, 1).command == name)),
             do: raise("Command #{name} runs no vanilla node or has no handler")

      for path <- Keyword.get(options(entry), :only, []),
          not match?(%{command: ^name}, nodes[path]),
          do: raise("Command path #{Enum.join(path, " ")} is not executable")
    end

    tables = {root, Map.new(0..4, &{&1, Tree.graph(root, &1)})}
    :persistent_term.put(__MODULE__, tables)
    tables
  end

  defp options({_module, _function}), do: []
  defp options({_module, _function, options}), do: options

  defp tables, do: :persistent_term.get(__MODULE__, nil) || init!()

  def root, do: elem(tables(), 0)
  def node!(path), do: Tree.node!(root(), path)

  @doc "The commands packet payload for a player at permission `level`."
  def graph_payload(level), do: Map.fetch!(elem(tables(), 1), level)

  @doc "The commands packet for a player at permission `level`."
  def packet(level), do: Valimc.Protocol.Packets.packet("commands", graph_payload(level))

  @doc "The handler module that suggests for `name`'s `ask_server` nodes, or nil."
  def suggester(name) do
    case registry()[name] do
      {module, _function, options} -> if options[:suggest], do: module
      _ -> nil
    end
  end

  @doc "The handler `{module, function}` of the top-level command `name`."
  def handler(name) do
    case Map.fetch!(registry(), name) do
      {module, function} -> {module, function}
      {module, function, _options} -> {module, function}
    end
  end

  @doc """
  Parses `input` for `source`: `{:ok, handler, arguments, context}` or
  `{:error, error}`. The arguments carry the parsed path's literals after the
  command's name (`:literals`).
  """
  def parse(input, source) do
    parse = Dispatcher.parse(root(), input, source)

    case Dispatcher.finish(parse) do
      {:ok, last, context} ->
        literals =
          for {%{type: :literal, path: [_, _ | _], name: name}, _} <- last.nodes, do: name

        arguments =
          last.arguments
          |> Map.new(fn {name, {value, _range}} -> {name, value} end)
          |> Map.put(:literals, literals)

        {:ok, handler(last.command), arguments, context}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Runs `input` (without `/`) as `source` in the calling process; parse errors
  and failures become feedback through the source's sink. Everything the
  command touches is addressed from the source (its dimension included), not
  from the calling process's context.
  """
  def run(%Source{} = source, input) do
    case parse(input, source) do
      {:ok, {module, function}, arguments, _context} ->
        execute(source, module, function, arguments)

      {:error, error} ->
        for message <- Error.feedback(error, input), do: Feedback.success(source, message, false)
    end

    :ok
  end

  @doc "Runs an RCON command (VMC-010g) and returns its output text."
  def execute_rcon(line) do
    source = Source.rcon()
    run(source, String.replace_prefix(line, "/", ""))
    Source.collect(source)
  end

  @doc "Runs a console line as the server (VMC-010f); a leading `/` is optional."
  def execute_console(line), do: run(Source.console(), String.replace_prefix(line, "/", ""))

  defp execute(source, module, function, arguments) do
    apply(module, function, [arguments, source])
  rescue
    exception ->
      failed(
        source,
        Exception.message(exception),
        Exception.format(:error, exception, __STACKTRACE__)
      )
  catch
    {:command_syntax, %Error{} = error} ->
      Feedback.failure(source, error.message)

    :exit, reason ->
      failed(
        source,
        Exception.format_exit(reason),
        Exception.format(:exit, reason, __STACKTRACE__)
      )
  end

  @doc """
  Vanilla's `command.failed`, with the reason on hover, for a command that
  raised, exited or ran out of time.
  """
  def failed(source, reason, log) do
    Logger.error("Command failed: " <> log)

    hover =
      {:compound, %{"action" => {:string, "show_text"}, "value" => Text.literal(reason)}}

    Feedback.failure(
      source,
      Text.translatable("command.failed") |> Text.style([{"hover_event", hover}])
    )
  end
end
