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
  require Logger
  alias Valimc.Command.{Arguments, Dispatcher, Error, Feedback, Source, Text, Tree}

  alias Valimc.Commands.{
    Admin,
    Chat,
    Effects,
    Players,
    PostEffects,
    Preview,
    Timers,
    World,
    WorldBorder
  }

  alias Valimc.Commands.Operators
  alias Valimc.Commands.Text, as: TextCommands
  alias Valimc.Commands.Blocks, as: BlockCommands

  @handlers %{
    ["help"] => {Chat, :help},
    ["help", "command"] => {Chat, :help_command},
    ["tellraw", "targets", "message"] => {TextCommands, :tellraw},
    ["title", "targets", "clear"] => {TextCommands, :title_clear},
    ["title", "targets", "reset"] => {TextCommands, :title_reset},
    ["title", "targets", "title", "title"] => {TextCommands, :title_title},
    ["title", "targets", "subtitle", "title"] => {TextCommands, :title_subtitle},
    ["title", "targets", "actionbar", "title"] => {TextCommands, :title_actionbar},
    ["title", "targets", "times", "fadeIn", "stay", "fadeOut"] => {TextCommands, :title_times},
    ["particle", "name"] => {Effects, :particle},
    ["particle", "name", "pos"] => {Effects, :particle},
    ["particle", "name", "pos", "delta", "speed", "count"] => {Effects, :particle},
    ["particle", "name", "pos", "delta", "speed", "count", "force"] => {Effects, :particle_force},
    ["particle", "name", "pos", "delta", "speed", "count", "force", "viewers"] =>
      {Effects, :particle_force},
    ["particle", "name", "pos", "delta", "speed", "count", "normal"] => {Effects, :particle},
    ["particle", "name", "pos", "delta", "speed", "count", "normal", "viewers"] =>
      {Effects, :particle},
    ["playsound", "sound"] => {Effects, :playsound},
    ["playsound", "sound", "master"] => {Effects, :playsound_master},
    ["playsound", "sound", "master", "targets"] => {Effects, :playsound_master},
    ["playsound", "sound", "master", "targets", "pos"] => {Effects, :playsound_master},
    ["playsound", "sound", "master", "targets", "pos", "volume"] => {Effects, :playsound_master},
    ["playsound", "sound", "master", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_master},
    ["playsound", "sound", "master", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_master},
    ["stopsound", "targets", "master"] => {Effects, :stopsound_master},
    ["stopsound", "targets", "master", "sound"] => {Effects, :stopsound_master},
    ["playsound", "sound", "music"] => {Effects, :playsound_music},
    ["playsound", "sound", "music", "targets"] => {Effects, :playsound_music},
    ["playsound", "sound", "music", "targets", "pos"] => {Effects, :playsound_music},
    ["playsound", "sound", "music", "targets", "pos", "volume"] => {Effects, :playsound_music},
    ["playsound", "sound", "music", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_music},
    ["playsound", "sound", "music", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_music},
    ["stopsound", "targets", "music"] => {Effects, :stopsound_music},
    ["stopsound", "targets", "music", "sound"] => {Effects, :stopsound_music},
    ["playsound", "sound", "record"] => {Effects, :playsound_record},
    ["playsound", "sound", "record", "targets"] => {Effects, :playsound_record},
    ["playsound", "sound", "record", "targets", "pos"] => {Effects, :playsound_record},
    ["playsound", "sound", "record", "targets", "pos", "volume"] => {Effects, :playsound_record},
    ["playsound", "sound", "record", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_record},
    ["playsound", "sound", "record", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_record},
    ["stopsound", "targets", "record"] => {Effects, :stopsound_record},
    ["stopsound", "targets", "record", "sound"] => {Effects, :stopsound_record},
    ["playsound", "sound", "weather"] => {Effects, :playsound_weather},
    ["playsound", "sound", "weather", "targets"] => {Effects, :playsound_weather},
    ["playsound", "sound", "weather", "targets", "pos"] => {Effects, :playsound_weather},
    ["playsound", "sound", "weather", "targets", "pos", "volume"] =>
      {Effects, :playsound_weather},
    ["playsound", "sound", "weather", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_weather},
    ["playsound", "sound", "weather", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_weather},
    ["stopsound", "targets", "weather"] => {Effects, :stopsound_weather},
    ["stopsound", "targets", "weather", "sound"] => {Effects, :stopsound_weather},
    ["playsound", "sound", "block"] => {Effects, :playsound_block},
    ["playsound", "sound", "block", "targets"] => {Effects, :playsound_block},
    ["playsound", "sound", "block", "targets", "pos"] => {Effects, :playsound_block},
    ["playsound", "sound", "block", "targets", "pos", "volume"] => {Effects, :playsound_block},
    ["playsound", "sound", "block", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_block},
    ["playsound", "sound", "block", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_block},
    ["stopsound", "targets", "block"] => {Effects, :stopsound_block},
    ["stopsound", "targets", "block", "sound"] => {Effects, :stopsound_block},
    ["playsound", "sound", "hostile"] => {Effects, :playsound_hostile},
    ["playsound", "sound", "hostile", "targets"] => {Effects, :playsound_hostile},
    ["playsound", "sound", "hostile", "targets", "pos"] => {Effects, :playsound_hostile},
    ["playsound", "sound", "hostile", "targets", "pos", "volume"] =>
      {Effects, :playsound_hostile},
    ["playsound", "sound", "hostile", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_hostile},
    ["playsound", "sound", "hostile", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_hostile},
    ["stopsound", "targets", "hostile"] => {Effects, :stopsound_hostile},
    ["stopsound", "targets", "hostile", "sound"] => {Effects, :stopsound_hostile},
    ["playsound", "sound", "neutral"] => {Effects, :playsound_neutral},
    ["playsound", "sound", "neutral", "targets"] => {Effects, :playsound_neutral},
    ["playsound", "sound", "neutral", "targets", "pos"] => {Effects, :playsound_neutral},
    ["playsound", "sound", "neutral", "targets", "pos", "volume"] =>
      {Effects, :playsound_neutral},
    ["playsound", "sound", "neutral", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_neutral},
    ["playsound", "sound", "neutral", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_neutral},
    ["stopsound", "targets", "neutral"] => {Effects, :stopsound_neutral},
    ["stopsound", "targets", "neutral", "sound"] => {Effects, :stopsound_neutral},
    ["playsound", "sound", "player"] => {Effects, :playsound_player},
    ["playsound", "sound", "player", "targets"] => {Effects, :playsound_player},
    ["playsound", "sound", "player", "targets", "pos"] => {Effects, :playsound_player},
    ["playsound", "sound", "player", "targets", "pos", "volume"] => {Effects, :playsound_player},
    ["playsound", "sound", "player", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_player},
    ["playsound", "sound", "player", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_player},
    ["stopsound", "targets", "player"] => {Effects, :stopsound_player},
    ["stopsound", "targets", "player", "sound"] => {Effects, :stopsound_player},
    ["playsound", "sound", "ambient"] => {Effects, :playsound_ambient},
    ["playsound", "sound", "ambient", "targets"] => {Effects, :playsound_ambient},
    ["playsound", "sound", "ambient", "targets", "pos"] => {Effects, :playsound_ambient},
    ["playsound", "sound", "ambient", "targets", "pos", "volume"] =>
      {Effects, :playsound_ambient},
    ["playsound", "sound", "ambient", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_ambient},
    ["playsound", "sound", "ambient", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_ambient},
    ["stopsound", "targets", "ambient"] => {Effects, :stopsound_ambient},
    ["stopsound", "targets", "ambient", "sound"] => {Effects, :stopsound_ambient},
    ["playsound", "sound", "voice"] => {Effects, :playsound_voice},
    ["playsound", "sound", "voice", "targets"] => {Effects, :playsound_voice},
    ["playsound", "sound", "voice", "targets", "pos"] => {Effects, :playsound_voice},
    ["playsound", "sound", "voice", "targets", "pos", "volume"] => {Effects, :playsound_voice},
    ["playsound", "sound", "voice", "targets", "pos", "volume", "pitch"] =>
      {Effects, :playsound_voice},
    ["playsound", "sound", "voice", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_voice},
    ["stopsound", "targets", "voice"] => {Effects, :stopsound_voice},
    ["stopsound", "targets", "voice", "sound"] => {Effects, :stopsound_voice},
    ["playsound", "sound", "ui"] => {Effects, :playsound_ui},
    ["playsound", "sound", "ui", "targets"] => {Effects, :playsound_ui},
    ["playsound", "sound", "ui", "targets", "pos"] => {Effects, :playsound_ui},
    ["playsound", "sound", "ui", "targets", "pos", "volume"] => {Effects, :playsound_ui},
    ["playsound", "sound", "ui", "targets", "pos", "volume", "pitch"] => {Effects, :playsound_ui},
    ["playsound", "sound", "ui", "targets", "pos", "volume", "pitch", "minVolume"] =>
      {Effects, :playsound_ui},
    ["stopsound", "targets", "ui"] => {Effects, :stopsound_ui},
    ["stopsound", "targets", "ui", "sound"] => {Effects, :stopsound_ui},
    ["stopsound", "targets"] => {Effects, :stopsound},
    ["stopsound", "targets", "*", "sound"] => {Effects, :stopsound},
    ["dialog", "show", "targets", "dialog"] => {Effects, :dialog_show},
    ["dialog", "clear", "targets"] => {Effects, :dialog_clear},
    ["posteffect", "add", "targets", "posteffect"] => {PostEffects, :add},
    ["posteffect", "remove", "targets", "posteffect"] => {PostEffects, :remove},
    ["posteffect", "clear", "targets"] => {PostEffects, :clear},
    ["posteffect", "list", "target"] => {PostEffects, :list},
    ["stopwatch", "create", "id"] => {Timers, :stopwatch_create},
    ["stopwatch", "query", "id"] => {Timers, :stopwatch_query},
    ["stopwatch", "query", "id", "scale"] => {Timers, :stopwatch_query},
    ["stopwatch", "restart", "id"] => {Timers, :stopwatch_restart},
    ["stopwatch", "remove", "id"] => {Timers, :stopwatch_remove},
    ["tick", "query"] => {Timers, :tick_query},
    ["tick", "rate", "rate"] => {Timers, :tick_rate},
    ["tick", "freeze"] => {Timers, :tick_freeze},
    ["tick", "unfreeze"] => {Timers, :tick_unfreeze},
    ["tick", "step"] => {Timers, :tick_step},
    ["tick", "step", "time"] => {Timers, :tick_step},
    ["tick", "step", "stop"] => {Timers, :tick_step_stop},
    ["tick", "sprint", "time"] => {Timers, :tick_sprint},
    ["tick", "sprint", "stop"] => {Timers, :tick_sprint_stop},
    ["clone", "begin", "end", "destination"] => {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "destination", "replace"] => {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "destination", "replace", "force"] =>
      {BlockCommands, :clone_replace_force},
    ["clone", "begin", "end", "destination", "replace", "move"] =>
      {BlockCommands, :clone_replace_move},
    ["clone", "begin", "end", "destination", "replace", "normal"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "destination", "masked"] => {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "destination", "masked", "force"] =>
      {BlockCommands, :clone_masked_force},
    ["clone", "begin", "end", "destination", "masked", "move"] =>
      {BlockCommands, :clone_masked_move},
    ["clone", "begin", "end", "destination", "masked", "normal"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "destination", "filtered", "filter"] =>
      {BlockCommands, :clone_filtered_normal},
    ["clone", "begin", "end", "destination", "filtered", "filter", "force"] =>
      {BlockCommands, :clone_filtered_force},
    ["clone", "begin", "end", "destination", "filtered", "filter", "move"] =>
      {BlockCommands, :clone_filtered_move},
    ["clone", "begin", "end", "destination", "filtered", "filter", "normal"] =>
      {BlockCommands, :clone_filtered_normal},
    ["clone", "begin", "end", "destination", "strict"] => {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "destination", "strict", "replace"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "destination", "strict", "replace", "force"] =>
      {BlockCommands, :clone_replace_force},
    ["clone", "begin", "end", "destination", "strict", "replace", "move"] =>
      {BlockCommands, :clone_replace_move},
    ["clone", "begin", "end", "destination", "strict", "replace", "normal"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "destination", "strict", "masked"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "destination", "strict", "masked", "force"] =>
      {BlockCommands, :clone_masked_force},
    ["clone", "begin", "end", "destination", "strict", "masked", "move"] =>
      {BlockCommands, :clone_masked_move},
    ["clone", "begin", "end", "destination", "strict", "masked", "normal"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "destination", "strict", "filtered", "filter"] =>
      {BlockCommands, :clone_filtered_normal},
    ["clone", "begin", "end", "destination", "strict", "filtered", "filter", "force"] =>
      {BlockCommands, :clone_filtered_force},
    ["clone", "begin", "end", "destination", "strict", "filtered", "filter", "move"] =>
      {BlockCommands, :clone_filtered_move},
    ["clone", "begin", "end", "destination", "strict", "filtered", "filter", "normal"] =>
      {BlockCommands, :clone_filtered_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "replace"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "replace", "force"] =>
      {BlockCommands, :clone_replace_force},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "replace", "move"] =>
      {BlockCommands, :clone_replace_move},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "replace", "normal"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "masked"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "masked", "force"] =>
      {BlockCommands, :clone_masked_force},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "masked", "move"] =>
      {BlockCommands, :clone_masked_move},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "masked", "normal"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "filtered", "filter"] =>
      {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter",
      "force"
    ] => {BlockCommands, :clone_filtered_force},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter",
      "move"
    ] => {BlockCommands, :clone_filtered_move},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter",
      "normal"
    ] => {BlockCommands, :clone_filtered_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "strict"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "strict", "replace"] =>
      {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "replace",
      "force"
    ] => {BlockCommands, :clone_replace_force},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "strict", "replace", "move"] =>
      {BlockCommands, :clone_replace_move},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "replace",
      "normal"
    ] => {BlockCommands, :clone_replace_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "strict", "masked"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "strict", "masked", "force"] =>
      {BlockCommands, :clone_masked_force},
    ["clone", "begin", "end", "to", "targetDimension", "destination", "strict", "masked", "move"] =>
      {BlockCommands, :clone_masked_move},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "masked",
      "normal"
    ] => {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter"
    ] => {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter",
      "force"
    ] => {BlockCommands, :clone_filtered_force},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter",
      "move"
    ] => {BlockCommands, :clone_filtered_move},
    [
      "clone",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter",
      "normal"
    ] => {BlockCommands, :clone_filtered_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "replace"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "replace", "force"] =>
      {BlockCommands, :clone_replace_force},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "replace", "move"] =>
      {BlockCommands, :clone_replace_move},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "replace", "normal"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "masked"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "masked", "force"] =>
      {BlockCommands, :clone_masked_force},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "masked", "move"] =>
      {BlockCommands, :clone_masked_move},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "masked", "normal"] =>
      {BlockCommands, :clone_masked_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "filtered", "filter"] =>
      {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "filtered",
      "filter",
      "force"
    ] => {BlockCommands, :clone_filtered_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "filtered",
      "filter",
      "move"
    ] => {BlockCommands, :clone_filtered_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "filtered",
      "filter",
      "normal"
    ] => {BlockCommands, :clone_filtered_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "strict"] =>
      {BlockCommands, :clone_replace_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "strict", "replace"] =>
      {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "replace",
      "force"
    ] => {BlockCommands, :clone_replace_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "replace",
      "move"
    ] => {BlockCommands, :clone_replace_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "replace",
      "normal"
    ] => {BlockCommands, :clone_replace_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "destination", "strict", "masked"] =>
      {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "masked",
      "force"
    ] => {BlockCommands, :clone_masked_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "masked",
      "move"
    ] => {BlockCommands, :clone_masked_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "masked",
      "normal"
    ] => {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "filtered",
      "filter"
    ] => {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "filtered",
      "filter",
      "force"
    ] => {BlockCommands, :clone_filtered_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "filtered",
      "filter",
      "move"
    ] => {BlockCommands, :clone_filtered_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "destination",
      "strict",
      "filtered",
      "filter",
      "normal"
    ] => {BlockCommands, :clone_filtered_normal},
    ["clone", "from", "sourceDimension", "begin", "end", "to", "targetDimension", "destination"] =>
      {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "replace"
    ] => {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "replace",
      "force"
    ] => {BlockCommands, :clone_replace_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "replace",
      "move"
    ] => {BlockCommands, :clone_replace_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "replace",
      "normal"
    ] => {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "masked"
    ] => {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "masked",
      "force"
    ] => {BlockCommands, :clone_masked_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "masked",
      "move"
    ] => {BlockCommands, :clone_masked_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "masked",
      "normal"
    ] => {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter"
    ] => {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter",
      "force"
    ] => {BlockCommands, :clone_filtered_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter",
      "move"
    ] => {BlockCommands, :clone_filtered_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "filtered",
      "filter",
      "normal"
    ] => {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict"
    ] => {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "replace"
    ] => {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "replace",
      "force"
    ] => {BlockCommands, :clone_replace_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "replace",
      "move"
    ] => {BlockCommands, :clone_replace_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "replace",
      "normal"
    ] => {BlockCommands, :clone_replace_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "masked"
    ] => {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "masked",
      "force"
    ] => {BlockCommands, :clone_masked_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "masked",
      "move"
    ] => {BlockCommands, :clone_masked_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "masked",
      "normal"
    ] => {BlockCommands, :clone_masked_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter"
    ] => {BlockCommands, :clone_filtered_normal},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter",
      "force"
    ] => {BlockCommands, :clone_filtered_force},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter",
      "move"
    ] => {BlockCommands, :clone_filtered_move},
    [
      "clone",
      "from",
      "sourceDimension",
      "begin",
      "end",
      "to",
      "targetDimension",
      "destination",
      "strict",
      "filtered",
      "filter",
      "normal"
    ] => {BlockCommands, :clone_filtered_normal},
    ["forceload", "add", "from"] => {BlockCommands, :forceload_add},
    ["forceload", "add", "from", "to"] => {BlockCommands, :forceload_add},
    ["forceload", "remove", "from"] => {BlockCommands, :forceload_remove},
    ["forceload", "remove", "from", "to"] => {BlockCommands, :forceload_remove},
    ["forceload", "remove", "all"] => {BlockCommands, :forceload_remove_all},
    ["forceload", "query"] => {BlockCommands, :forceload_query},
    ["forceload", "query", "pos"] => {BlockCommands, :forceload_query_pos},
    ["op", "targets"] => {Operators, :op},
    ["deop", "targets"] => {Operators, :deop},
    ["ban", "targets"] => {Operators, :ban},
    ["ban", "targets", "reason"] => {Operators, :ban},
    ["ban-ip", "target"] => {Operators, :ban_ip},
    ["ban-ip", "target", "reason"] => {Operators, :ban_ip},
    ["banlist"] => {Operators, :banlist},
    ["banlist", "ips"] => {Operators, :banlist_ips},
    ["banlist", "players"] => {Operators, :banlist_players},
    ["pardon", "targets"] => {Operators, :pardon},
    ["pardon-ip", "target"] => {Operators, :pardon_ip},
    ["whitelist", "on"] => {Operators, :whitelist_on},
    ["whitelist", "off"] => {Operators, :whitelist_off},
    ["whitelist", "list"] => {Operators, :whitelist_list},
    ["whitelist", "add", "targets"] => {Operators, :whitelist_add},
    ["whitelist", "remove", "targets"] => {Operators, :whitelist_remove},
    ["whitelist", "reload"] => {Operators, :whitelist_reload},
    ["transfer", "hostname"] => {Operators, :transfer},
    ["transfer", "hostname", "port"] => {Operators, :transfer},
    ["transfer", "hostname", "port", "players"] => {Operators, :transfer},
    ["locate", "structure", "structure"] => {Valimc.Commands.Locate, :structure},
    ["save-all"] => {Valimc.Commands.Server, :save_all},
    ["save-all", "flush"] => {Valimc.Commands.Server, :save_all_flush},
    ["save-on"] => {Valimc.Commands.Server, :save_on},
    ["save-off"] => {Valimc.Commands.Server, :save_off},
    ["setidletimeout", "minutes"] => {Valimc.Commands.Server, :setidletimeout},
    ["version"] => {Admin, :version},
    ["kick", "targets"] => {Admin, :kick},
    ["kick", "targets", "reason"] => {Admin, :kick},
    ["stop"] => {Admin, :stop},
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
    ["teleport", "targets", "location", "rotation"] => {Players, :teleport},
    ["worldborder", "add", "distance"] => {WorldBorder, :add},
    ["worldborder", "add", "distance", "time"] => {WorldBorder, :add},
    ["worldborder", "set", "distance"] => {WorldBorder, :set},
    ["worldborder", "set", "distance", "time"] => {WorldBorder, :set},
    ["worldborder", "center", "pos"] => {WorldBorder, :center},
    ["worldborder", "damage", "amount", "damagePerBlock"] => {WorldBorder, :damage_amount},
    ["worldborder", "damage", "buffer", "distance"] => {WorldBorder, :damage_buffer},
    ["worldborder", "get"] => {WorldBorder, :get},
    ["worldborder", "warning", "distance", "distance"] => {WorldBorder, :warning_distance},
    ["worldborder", "warning", "time", "time"] => {WorldBorder, :warning_time}
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

  # The tree, its node index and the graphs are kept as one external-term
  # literal: as code they are slow to compile. They are decoded once.
  @tables :erlang.term_to_binary({@root, @nodes, @graphs})
  @tables_key {__MODULE__, :erlang.md5(@tables)}

  defp tables do
    case :persistent_term.get(@tables_key, nil) do
      nil ->
        tables = :erlang.binary_to_term(@tables)
        :persistent_term.put(@tables_key, tables)
        tables

      tables ->
        tables
    end
  end

  def root, do: elem(tables(), 0)
  def node!(path), do: Map.fetch!(elem(tables(), 1), path)
  def handlers, do: @handlers

  @doc "The commands packet payload for a player at permission `level`."
  def graph_payload(level), do: Map.fetch!(elem(tables(), 2), level)

  @doc "Parses `input` for `source`: `{:ok, handler, arguments, context}` or `{:error, error}`."
  def parse(input, source) do
    parse = Dispatcher.parse(root(), input, source)

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

  @doc "Runs a console line as the server (VMC-010f); a leading `/` is optional."
  def execute_console(line) do
    input = String.replace_prefix(line, "/", "")
    source = Source.console()

    case parse(input, source) do
      {:ok, {module, function}, arguments, _context} ->
        run(source, module, function, arguments)

      {:error, error} ->
        for message <- Error.feedback(error, input), do: Feedback.success(source, message, false)
    end

    :ok
  end

  defp run(source, module, function, arguments) do
    {_result, state} = apply(module, function, [arguments, source])
    state
  rescue
    exception ->
      # Vanilla's `command.failed`, with the exception on hover; the session lives on.
      Logger.error("Command failed: " <> Exception.format(:error, exception, __STACKTRACE__))

      hover =
        {:compound,
         %{
           "action" => {:string, "show_text"},
           "value" => Text.literal(Exception.message(exception))
         }}

      Feedback.failure(
        source,
        Text.translatable("command.failed") |> Text.style([{"hover_event", hover}])
      )

      source.state
  catch
    {:command_syntax, %Error{} = error} ->
      Feedback.failure(source, error.message)
      source.state
  end
end
