defmodule Valimc.Commands.Operators do
  @moduledoc """
  Dedicated-server administration (VMC-053f2 on VMC-010a): `op`, `deop`, `ban`,
  `ban-ip`, `banlist`, `pardon`, `pardon-ip`, `whitelist` and `transfer`,
  over `Valimc.Admin.Lists`.
  """
  alias Valimc.Admin.{Lists, Login}
  alias Valimc.World.Settings
  alias Valimc.Text.Error
  alias Valimc.Commands.{Feedback, Source, Targets}
  alias Valimc.Text
  alias Valimc.Protocol.{Packets, Wire}

  # ---- profiles ----

  @doc "`GameProfileArgument.getGameProfiles`: online players, or a resolved name."
  def profiles(source, {:selector, selector}),
    do: source |> Targets.required_players(selector) |> Enum.map(&Map.take(&1, [:uuid, :name]))

  def profiles(_source, {:name, name}) do
    case Lists.resolve(name) do
      {:ok, profile} -> [profile]
      :unknown -> Error.fail!("argument.player.unknown")
    end
  end

  defp online(uuid), do: Targets.by_uuid(uuid)

  defp disconnect(player, reason),
    do: Valimc.Net.Connection.deliver(player.pid, {:kick, Text.encode(reason)})

  # `PlayerList.sendPlayerPermissionLevel`: the level event and a new command tree.
  defp push_level(uuid) do
    with %{} = player <- online(uuid) do
      level = Valimc.Admin.Permissions.level(player)

      for packet <- [Packets.permission_level(player.entity_id, level), Packets.commands(level)],
          do: Valimc.Net.Connection.deliver(player.pid, {:packet, packet})
    end
  end

  # `kickUnlistedPlayers`: only with `enforce-whitelist`; operators are not exempt.
  defp kick_unlisted do
    if Valimc.config(:enforce_whitelist) == true and Settings.get(:white_list) do
      for player <- Valimc.Commands.Targets.online(),
          not Lists.whitelisted?(player.uuid),
          do: disconnect(player, Text.translatable("multiplayer.disconnect.not_whitelisted"))
    end
  end

  defp changed!(_source, {:error, reason}, _key, _message), do: unsaved!(reason)
  defp changed!(_source, [], key, _message), do: Error.fail!(key)

  defp changed!(source, changed, _key, message) do
    for profile <- changed, do: Feedback.success(source, message.(profile))
    length(changed)
  end

  @doc "Names the dedicated server suggests (VMC-053f2): `op`, `deop`, `pardon`, `pardon-ip`, `whitelist add|remove`."
  def suggest(["op" | _], _arguments, _source),
    do:
      {:names, for(p <- Targets.online(), not Valimc.Admin.Permissions.operator?(p), do: p.name)}

  def suggest(["deop" | _], _arguments, _source),
    do: {:names, for({_, op} <- Lists.entries(:ops), do: op.name)}

  def suggest(["pardon" | _], _arguments, _source),
    do: {:names, for({_, entry} <- Lists.entries(:bans), do: entry["name"])}

  def suggest(["pardon-ip" | _], _arguments, _source),
    do: {:names, Map.keys(Lists.entries(:ip_bans))}

  def suggest(["whitelist", "add" | _], _arguments, _source),
    do: {:names, for(p <- Targets.online(), not Lists.whitelisted?(p.uuid), do: p.name)}

  def suggest(["whitelist", "remove" | _], _arguments, _source),
    do: {:names, Map.values(Lists.entries(:whitelist))}

  def suggest(_path, _arguments, _source), do: {:names, []}

  # ---- op, deop ----

  def op(%{"targets" => targets}, source) do
    changed = Lists.add_ops(profiles(source, targets), Valimc.config(:operator_level))
    for profile <- changed, do: push_level(profile.uuid)

    changed!(source, changed, "commands.op.failed", fn profile ->
      Text.translatable("commands.op.success", [profile.name])
    end)
  end

  def deop(%{"targets" => targets}, source) do
    changed = Lists.remove_ops(profiles(source, targets))
    for profile <- changed, do: push_level(profile.uuid)

    result =
      changed!(source, changed, "commands.deop.failed", fn profile ->
        Text.translatable("commands.deop.success", [profile.name])
      end)

    kick_unlisted()
    result
  end

  # ---- bans ----

  defp reason(%{"reason" => message}, source),
    do: Text.plain(Valimc.Commands.Chat.resolve(source, message))

  defp reason(_arguments, _source), do: nil

  def ban(%{"targets" => targets} = arguments, source) do
    entry = Lists.ban_entry(source.name, reason(arguments, source))
    changed = Lists.ban_players(profiles(source, targets), entry)

    result =
      changed!(source, changed, "commands.ban.failed", fn profile ->
        Text.translatable("commands.ban.success", [
          Text.literal(profile.name),
          Login.reason(Map.new(entry))
        ])
      end)

    for profile <- changed,
        player = online(profile.uuid),
        player != nil,
        do: disconnect(player, Text.translatable("multiplayer.disconnect.banned"))

    result
  end

  def pardon(%{"targets" => targets}, source) do
    changed = Lists.pardon_players(profiles(source, targets))

    changed!(source, changed, "commands.pardon.failed", fn profile ->
      Text.translatable("commands.pardon.success", [Text.literal(profile.name)])
    end)
  end

  @doc "Guava's `InetAddresses.isInetAddress` for what a word can hold: dotted IPv4."
  def ip_literal?(text) do
    case String.split(text, ".") do
      [_, _, _, _] = parts -> Enum.all?(parts, &octet?/1)
      _ -> false
    end
  end

  defp octet?(part) do
    Regex.match?(~r/\A(0|[1-9][0-9]{0,2})\z/, part) and String.to_integer(part) <= 255
  end

  def ban_ip(%{"target" => target} = arguments, source) do
    ip =
      cond do
        ip_literal?(target) ->
          target

        player =
            Enum.find(
              Valimc.Commands.Targets.online(),
              &(String.downcase(&1.name) == String.downcase(target))
            ) ->
          player[:address] || Error.fail!("commands.banip.invalid")

        true ->
          Error.fail!("commands.banip.invalid")
      end

    entry = Lists.ban_entry(source.name, reason(arguments, source))

    case Lists.ban_ip(ip, entry) do
      :already -> Error.fail!("commands.banip.failed")
      {:error, reason} -> unsaved!(reason)
      :ok -> :ok
    end

    players = Enum.filter(Valimc.Commands.Targets.online(), &(&1.address == ip))

    Feedback.success(
      source,
      Text.translatable("commands.banip.success", [ip, Login.reason(Map.new(entry))])
    )

    if players != [] do
      Feedback.success(
        source,
        Text.translatable("commands.banip.info", [
          length(players),
          Valimc.Commands.Chat.join_names(players)
        ])
      )
    end

    for player <- players,
        do: disconnect(player, Text.translatable("multiplayer.disconnect.ip_banned"))

    length(players)
  end

  def pardon_ip(%{"target" => target}, source) do
    unless ip_literal?(target), do: Error.fail!("commands.pardonip.invalid")

    case Lists.pardon_ip(target) do
      :not_banned -> Error.fail!("commands.pardonip.failed")
      {:error, reason} -> unsaved!(reason)
      :ok -> :ok
    end

    Feedback.success(source, Text.translatable("commands.pardonip.success", [target]))
    1
  end

  @doc "`/banlist [ips|players]`."
  def banlist(%{literals: literals}, source) do
    lines =
      case literals do
        [] -> ban_lines(:bans) ++ ban_lines(:ip_bans)
        ["players"] -> ban_lines(:bans)
        ["ips"] -> ban_lines(:ip_bans)
      end

    list_bans(source, lines)
  end

  defp ban_lines(kind) do
    for {key, entry} <- Enum.sort_by(Lists.entries(kind), &elem(&1, 1)["created"]) do
      name = if kind == :bans, do: entry["name"], else: key

      Text.translatable("commands.banlist.entry", [
        Text.literal(name),
        entry["source"],
        Login.reason(entry)
      ])
    end
  end

  defp list_bans(source, []) do
    Feedback.success(source, Text.translatable("commands.banlist.none"), false)
    0
  end

  defp list_bans(source, lines) do
    Feedback.success(source, Text.translatable("commands.banlist.list", [length(lines)]), false)
    for line <- lines, do: Feedback.success(source, line, false)
    length(lines)
  end

  # ---- whitelist ----

  @doc "`/whitelist on|off|list|add <targets>|remove <targets>|reload`."
  def whitelist(%{literals: [mode]} = arguments, source) do
    case mode do
      "on" -> whitelist_on(source)
      "off" -> whitelist_off(source)
      "list" -> whitelist_list(source)
      "add" -> whitelist_add(arguments, source)
      "remove" -> whitelist_remove(arguments, source)
      "reload" -> whitelist_reload(source)
    end
  end

  defp whitelist_on(source) do
    switch!(true, "commands.whitelist.alreadyOn")
    Feedback.success(source, Text.translatable("commands.whitelist.enabled"))
    kick_unlisted()
    1
  end

  defp whitelist_off(source) do
    switch!(false, "commands.whitelist.alreadyOff")
    Feedback.success(source, Text.translatable("commands.whitelist.disabled"))
    1
  end

  defp switch!(on, already) do
    case Settings.put(white_list: on) do
      :ok -> :ok
      :unchanged -> Error.fail!(already)
      {:error, reason} -> unsaved!(reason)
    end
  end

  # The list file could not be written; nothing changed.
  defp unsaved!(reason), do: Error.refuse!("The change could not be saved (#{inspect(reason)})")

  defp whitelist_list(source) do
    names = Lists.entries(:whitelist) |> Map.values() |> Enum.sort()

    if names == [],
      do: Feedback.success(source, Text.translatable("commands.whitelist.none"), false),
      else:
        Feedback.success(
          source,
          Text.translatable("commands.whitelist.list", [length(names), Enum.join(names, ", ")]),
          false
        )

    length(names)
  end

  defp whitelist_add(%{"targets" => targets}, source) do
    changed = Lists.whitelist_add(profiles(source, targets))

    changed!(source, changed, "commands.whitelist.add.failed", fn profile ->
      Text.translatable("commands.whitelist.add.success", [Text.literal(profile.name)])
    end)
  end

  defp whitelist_remove(%{"targets" => targets}, source) do
    changed = Lists.whitelist_remove(profiles(source, targets))

    result =
      changed!(source, changed, "commands.whitelist.remove.failed", fn profile ->
        Text.translatable("commands.whitelist.remove.success", [Text.literal(profile.name)])
      end)

    kick_unlisted()
    result
  end

  defp whitelist_reload(source) do
    Lists.reload_whitelist()
    Feedback.success(source, Text.translatable("commands.whitelist.reloaded"))
    kick_unlisted()
    1
  end

  # ---- transfer ----

  def transfer(%{"hostname" => host} = arguments, source) do
    port = Map.get(arguments, "port", 25565)

    players =
      case arguments do
        %{"players" => selector} -> Targets.required_players(source, selector)
        _ -> [Source.player!(source)]
      end

    packet = Packets.packet("transfer", [Wire.string(host), Wire.varint(port)])

    for player <- players, do: Valimc.Net.Connection.deliver(player.pid, {:packet, packet})

    message =
      case players do
        [one] ->
          Text.translatable("commands.transfer.success.single", [
            Source.display_name(one),
            host,
            port
          ])

        many ->
          Text.translatable("commands.transfer.success.multiple", [length(many), host, port])
      end

    Feedback.success(source, message)
    length(players)
  end
end
