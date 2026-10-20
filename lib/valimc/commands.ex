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
  alias Valimc.Commands.{Chat, Players, Preview, World}

  @handlers %{
    ["help"] => {Chat, :help},
    ["help", "command"] => {Chat, :help_command},
    ["time", "set", "time"] => {World, :time_set},
    ["time", "set", "timemarker"] => {World, :time_set_marker},
    ["time", "add", "time"] => {World, :time_add},
    ["time", "pause"] => {World, :time_pause},
    ["time", "resume"] => {World, :time_resume},
    ["time", "rate", "rate"] => {World, :time_rate},
    ["time", "query", "time"] => {World, :time_query},
    ["time", "query", "timeline"] => {World, :time_query_timeline},
    ["time", "query", "timeline", "repetition"] => {World, :time_query_repetition},
    ["time", "of", "clock", "set", "time"] => {World, :time_set},
    ["time", "of", "clock", "set", "timemarker"] => {World, :time_set_marker},
    ["time", "of", "clock", "add", "time"] => {World, :time_add},
    ["time", "of", "clock", "pause"] => {World, :time_pause},
    ["time", "of", "clock", "resume"] => {World, :time_resume},
    ["time", "of", "clock", "rate", "rate"] => {World, :time_rate},
    ["time", "of", "clock", "query", "time"] => {World, :time_query},
    ["time", "of", "clock", "query", "timeline"] => {World, :time_query_timeline},
    ["time", "of", "clock", "query", "timeline", "repetition"] => {World, :time_query_repetition},
    ["time", "query", "gametime"] => {World, :time_query_gametime},
    ["weather", "clear"] => {World, :weather_clear},
    ["weather", "clear", "duration"] => {World, :weather_clear},
    ["weather", "rain"] => {World, :weather_rain},
    ["weather", "rain", "duration"] => {World, :weather_rain},
    ["weather", "thunder"] => {World, :weather_thunder},
    ["weather", "thunder", "duration"] => {World, :weather_thunder},
    ["difficulty"] => {World, :difficulty_query},
    ["difficulty", "peaceful"] => {World, :difficulty_peaceful},
    ["difficulty", "easy"] => {World, :difficulty_easy},
    ["difficulty", "normal"] => {World, :difficulty_normal},
    ["difficulty", "hard"] => {World, :difficulty_hard},
    ["gamerule", "advance_time"] => {World, :gamerule_query_advance_time},
    ["gamerule", "advance_time", "value"] => {World, :gamerule_set_advance_time},
    ["gamerule", "minecraft:advance_time"] => {World, :gamerule_query_advance_time},
    ["gamerule", "minecraft:advance_time", "value"] => {World, :gamerule_set_advance_time},
    ["gamerule", "advance_weather"] => {World, :gamerule_query_advance_weather},
    ["gamerule", "advance_weather", "value"] => {World, :gamerule_set_advance_weather},
    ["gamerule", "minecraft:advance_weather"] => {World, :gamerule_query_advance_weather},
    ["gamerule", "minecraft:advance_weather", "value"] => {World, :gamerule_set_advance_weather},
    ["gamerule", "natural_health_regeneration"] =>
      {World, :gamerule_query_natural_health_regeneration},
    ["gamerule", "natural_health_regeneration", "value"] =>
      {World, :gamerule_set_natural_health_regeneration},
    ["gamerule", "minecraft:natural_health_regeneration"] =>
      {World, :gamerule_query_natural_health_regeneration},
    ["gamerule", "minecraft:natural_health_regeneration", "value"] =>
      {World, :gamerule_set_natural_health_regeneration},
    ["setblock", "pos", "block"] => {World, :setblock},
    ["setblock", "pos", "block", "replace"] => {World, :setblock},
    ["setblock", "pos", "block", "strict"] => {World, :setblock},
    ["setblock", "pos", "block", "keep"] => {World, :setblock_keep},
    ["fill", "from", "to", "block"] => {World, :fill},
    ["fill", "from", "to", "block", "replace"] => {World, :fill},
    ["fill", "from", "to", "block", "strict"] => {World, :fill},
    ["fill", "from", "to", "block", "outline"] => {World, :fill_outline},
    ["fill", "from", "to", "block", "hollow"] => {World, :fill_hollow},
    ["fill", "from", "to", "block", "keep"] => {World, :fill_keep},
    ["fill", "from", "to", "block", "replace", "filter"] => {World, :fill},
    ["fill", "from", "to", "block", "replace", "filter", "strict"] => {World, :fill},
    ["fill", "from", "to", "block", "replace", "filter", "outline"] => {World, :fill_outline},
    ["fill", "from", "to", "block", "replace", "filter", "hollow"] => {World, :fill_hollow},
    ["setworldspawn"] => {World, :setworldspawn},
    ["setworldspawn", "pos"] => {World, :setworldspawn},
    ["setworldspawn", "pos", "rotation"] => {World, :setworldspawn},
    ["seed"] => {World, :seed},
    ["locate", "biome", "biome"] => {World, :locate_biome},
    ["say", "message"] => {Chat, :say},
    ["me", "action"] => {Chat, :me},
    ["msg", "targets", "message"] => {Chat, :msg},
    ["list"] => {Chat, :list},
    ["list", "uuids"] => {Chat, :list_uuids},
    ["gamemode", "gamemode"] => {Players, :gamemode},
    ["gamemode", "gamemode", "target"] => {Players, :gamemode},
    ["defaultgamemode", "gamemode"] => {Players, :default_gamemode},
    ["give", "targets", "item"] => {Players, :give},
    ["give", "targets", "item", "count"] => {Players, :give},
    ["clear"] => {Players, :clear},
    ["clear", "targets"] => {Players, :clear},
    ["clear", "targets", "item"] => {Players, :clear},
    ["clear", "targets", "item", "maxCount"] => {Players, :clear},
    ["effect", "give", "targets", "effect"] => {Players, :effect_give},
    ["effect", "give", "targets", "effect", "seconds"] => {Players, :effect_give},
    ["effect", "give", "targets", "effect", "seconds", "amplifier"] => {Players, :effect_give},
    ["effect", "give", "targets", "effect", "seconds", "amplifier", "hideParticles"] =>
      {Players, :effect_give},
    ["effect", "give", "targets", "effect", "infinite"] => {Players, :effect_infinite},
    ["effect", "give", "targets", "effect", "infinite", "amplifier"] =>
      {Players, :effect_infinite},
    ["effect", "give", "targets", "effect", "infinite", "amplifier", "hideParticles"] =>
      {Players, :effect_infinite},
    ["effect", "clear"] => {Players, :effect_clear},
    ["effect", "clear", "targets"] => {Players, :effect_clear},
    ["effect", "clear", "targets", "effect"] => {Players, :effect_clear},
    ["experience", "add", "target", "amount"] => {Players, :experience_add},
    ["experience", "add", "target", "amount", "points"] => {Players, :experience_add},
    ["experience", "add", "target", "amount", "levels"] => {Players, :experience_add_levels},
    ["experience", "set", "target", "amount"] => {Players, :experience_set},
    ["experience", "set", "target", "amount", "points"] => {Players, :experience_set},
    ["experience", "set", "target", "amount", "levels"] => {Players, :experience_set_levels},
    ["experience", "query", "target", "points"] => {Players, :experience_query_points},
    ["experience", "query", "target", "levels"] => {Players, :experience_query_levels},
    ["kill"] => {Players, :kill},
    ["kill", "targets"] => {Players, :kill},
    ["teleport", "destination"] => {Players, :teleport},
    ["teleport", "location"] => {Players, :teleport},
    ["teleport", "targets", "destination"] => {Players, :teleport},
    ["teleport", "targets", "location"] => {Players, :teleport},
    ["teleport", "targets", "location", "facing", "entity", "facingEntity"] =>
      {Players, :teleport},
    ["teleport", "targets", "location", "facing", "entity", "facingEntity", "facingAnchor"] =>
      {Players, :teleport},
    ["teleport", "targets", "location", "facing", "facingLocation"] => {Players, :teleport},
    ["teleport", "targets", "location", "rotation"] => {Players, :teleport}
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
