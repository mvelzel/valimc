defmodule Valimc.Commands.Admin do
  @moduledoc """
  Server administration commands that need no operator list (VMC-053f):
  `version`, `kick` and `stop`. Operator, ban and whitelist commands wait for
  VMC-010.
  """
  alias Valimc.Command.{Error, Feedback, Source, Text}
  import Valimc.Net.Codec, only: [send_packets: 2]

  @facts :json.decode(File.read!(Path.expand("../../../priv/commands/facts.json", __DIR__)))
  @external_resource Path.expand("../../../priv/commands/facts.json", __DIR__)
  @version @facts["server_version"]

  @doc "`/version`: ten system lines, as vanilla's `VersionCommand`."
  def version(_arguments, source) do
    built =
      @version["build_time_ms"]
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%a %b %d %H:%M:%S UTC %Y")

    protocol = @version["protocol"]

    lines = [
      Text.translatable("commands.version.header"),
      Text.translatable("commands.version.id", [@version["id"]]),
      Text.translatable("commands.version.name", [@version["name"]]),
      Text.translatable("commands.version.data", [@version["data"]]),
      Text.translatable("commands.version.series", [@version["series"]]),
      Text.translatable("commands.version.protocol", [
        protocol,
        "0x" <> String.downcase(Integer.to_string(protocol, 16))
      ]),
      Text.translatable("commands.version.build_time", [Text.literal(built)]),
      Text.translatable("commands.version.pack.resource", [@version["resource_pack"]]),
      Text.translatable("commands.version.pack.data", [@version["data_pack"]]),
      Text.translatable(
        if(@version["stable"],
          do: "commands.version.stable.yes",
          else: "commands.version.stable.no"
        )
      )
    ]

    send_packets(source.state, Enum.map(lines, &Valimc.Protocol.Packets.chat(Text.encode(&1))))
    {1, source.state}
  end

  @doc "`/kick <targets> [<reason>]`."
  def kick(%{"targets" => selector} = arguments, source) do
    targets = Source.required_players(source, selector)

    reason =
      case arguments do
        %{"reason" => message} -> Valimc.Commands.Chat.resolve(source, message)
        _ -> Text.translatable("multiplayer.disconnect.kicked")
      end

    if targets == [], do: Error.fail!("commands.kick.owner.failed")

    {others, self} = Enum.split_with(targets, &(&1.pid != self()))

    for target <- others do
      Valimc.Connection.deliver(target.pid, {:kick, Text.encode(reason)})

      Feedback.success(
        source,
        Text.translatable("commands.kick.success", [Source.display_name(target), reason])
      )
    end

    if self != [] do
      Feedback.success(
        source,
        Text.translatable("commands.kick.success", [Source.display_name(source), reason])
      )

      Valimc.Net.Codec.reject(source.state, Text.encode(reason))
    end

    {length(targets), source.state}
  end

  @doc "`/stop`: announce, then a graceful shutdown that saves the world."
  def stop(_arguments, source) do
    Feedback.success(source, Text.translatable("commands.stop.stopping"))
    spawn(fn -> System.stop() end)
    {1, source.state}
  end
end
