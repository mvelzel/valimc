defmodule Valimc.Commands.Admin do
  @moduledoc """
  Server administration commands that need no operator list (VMC-053f):
  `version`, `kick` and `stop`. Operator, ban and whitelist commands wait for
  VMC-010.
  """
  alias Valimc.Text.Error
  alias Valimc.Commands.{Feedback, Source, Targets}
  alias Valimc.Text

  @doc "`/version`: ten system lines, as vanilla's `VersionCommand`."
  def version(_arguments, source) do
    built =
      Valimc.Commands.Facts.server_version()["build_time_ms"]
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%a %b %d %H:%M:%S UTC %Y")

    protocol = Valimc.Commands.Facts.server_version()["protocol"]

    lines = [
      Text.translatable("commands.version.header"),
      Text.translatable("commands.version.id", [Valimc.Commands.Facts.server_version()["id"]]),
      Text.translatable("commands.version.name", [Valimc.Commands.Facts.server_version()["name"]]),
      Text.translatable("commands.version.data", [Valimc.Commands.Facts.server_version()["data"]]),
      Text.translatable("commands.version.series", [
        Valimc.Commands.Facts.server_version()["series"]
      ]),
      Text.translatable("commands.version.protocol", [
        protocol,
        "0x" <> String.downcase(Integer.to_string(protocol, 16))
      ]),
      Text.translatable("commands.version.build_time", [Text.literal(built)]),
      Text.translatable("commands.version.pack.resource", [
        Valimc.Commands.Facts.server_version()["resource_pack"]
      ]),
      Text.translatable("commands.version.pack.data", [
        Valimc.Commands.Facts.server_version()["data_pack"]
      ]),
      Text.translatable(
        if(Valimc.Commands.Facts.server_version()["stable"],
          do: "commands.version.stable.yes",
          else: "commands.version.stable.no"
        )
      )
    ]

    for line <- lines, do: Feedback.success(source, line, false)
    1
  end

  @doc "`/kick <targets> [<reason>]`."
  def kick(%{"targets" => selector} = arguments, source) do
    targets = Targets.required_players(source, selector)

    reason =
      case arguments do
        %{"reason" => message} -> Valimc.Commands.Chat.resolve(source, message)
        _ -> Text.translatable("multiplayer.disconnect.kicked")
      end

    if targets == [], do: Error.fail!("commands.kick.owner.failed")

    # `KickCommand`: the disconnect, then the feedback (which a kicked source misses).
    for target <- targets do
      Valimc.Player.PlayerList.deliver(target.pid, {:kick, Text.encode(reason)})

      Feedback.success(
        source,
        Text.translatable("commands.kick.success", [Source.display_name(target), reason])
      )
    end

    length(targets)
  end

  @doc "`/stop`: announce, then a graceful shutdown that saves the world."
  def stop(_arguments, source) do
    Feedback.success(source, Text.translatable("commands.stop.stopping"))
    spawn(fn -> System.stop() end)
    1
  end
end
