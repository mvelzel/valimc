defmodule Valimc.Command.Selector do
  @moduledoc """
  Vanilla entity selectors (VMC-053): `EntitySelectorParser` and its options with
  vanilla's errors and cursors, and resolution against ValiMC's players.

  Only players are selectable entities today; `@e`, `@n` and `type=` therefore
  resolve to players, and non-player predicates select nothing.
  """
  alias Valimc.Command.{Error, Identifier, Range, Reader, Registries}

  defstruct max_results: 1,
            includes_entities: false,
            world_limited: false,
            predicates: [],
            distance: nil,
            level: nil,
            x: nil,
            y: nil,
            z: nil,
            dx: nil,
            dy: nil,
            dz: nil,
            rot_x: nil,
            rot_y: nil,
            order: :arbitrary,
            current_entity: false,
            player_name: nil,
            uuid: nil,
            type: nil,
            uses_selectors: false,
            options: %{}

  @int_max 2_147_483_647

  @doc "Parses a selector, name or UUID at the reader (`EntitySelectorParser.parse`)."
  def parse(reader, allow_selectors) do
    if Reader.at?(reader, ?@) do
      unless allow_selectors,
        do: Error.fail_at!("argument.entity.selector.not_allowed", [], reader)

      parse_selector(Reader.skip(reader), %__MODULE__{uses_selectors: true})
    else
      parse_name_or_uuid(reader)
    end
    |> then(fn {selector, reader} -> {finalize(selector), reader} end)
  end

  defp parse_selector(reader, s) do
    unless Reader.can_read?(reader),
      do: Error.fail_at!("argument.entity.selector.missing", [], reader)

    start = reader.cursor
    {type, reader} = Reader.read(reader)

    {s, alive} =
      case type do
        ?a ->
          {%{s | max_results: @int_max, order: :arbitrary, type: "minecraft:player"}, false}

        ?e ->
          {%{s | max_results: @int_max, includes_entities: true, order: :arbitrary}, true}

        ?n ->
          {%{s | max_results: 1, includes_entities: true, order: :nearest}, true}

        ?p ->
          {%{s | max_results: 1, order: :nearest, type: "minecraft:player"}, false}

        ?r ->
          {%{s | max_results: 1, order: :random, type: "minecraft:player"}, false}

        ?s ->
          {%{s | max_results: 1, includes_entities: true, current_entity: true}, false}

        _ ->
          Error.fail_at!(
            "argument.entity.selector.unknown",
            ["@" <> unit(type)],
            Reader.set_cursor(reader, start)
          )
      end

    s = if alive, do: add(s, :alive), else: s

    if Reader.at?(reader, ?[),
      do: parse_options(Reader.skip(reader), s),
      else: {s, reader}
  end

  defp unit(c), do: :unicode.characters_to_binary(<<c::16>>, :utf16, :utf8)

  defp parse_name_or_uuid(reader) do
    start = reader.cursor
    {name, reader} = Reader.read_string(reader)

    s =
      case uuid(name) do
        {:ok, uuid} ->
          %__MODULE__{uuid: uuid, includes_entities: true}

        :error ->
          if name == "" or String.length(name) > 16 or utf16_length(name) > 16,
            do: Error.fail_at!("argument.entity.invalid", [], Reader.set_cursor(reader, start))

          %__MODULE__{player_name: name}
      end

    {%{s | max_results: 1}, reader}
  end

  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, :utf16)), 2)

  @doc "Java `UUID.fromString`: five hex groups split by four dashes, each at most 16 digits."
  def uuid(text) do
    with parts when length(parts) == 5 <- String.split(text, "-"),
         true <- String.length(text) <= 36,
         [a, b, c, d, e] <- Enum.map(parts, &hex/1),
         true <- Enum.all?([a, b, c, d, e], &is_integer/1) do
      most =
        Bitwise.bor(
          Bitwise.bsl(Bitwise.band(a, 0xFFFFFFFF), 32),
          Bitwise.bor(Bitwise.bsl(Bitwise.band(b, 0xFFFF), 16), Bitwise.band(c, 0xFFFF))
        )

      least =
        Bitwise.bor(Bitwise.bsl(Bitwise.band(d, 0xFFFF), 48), Bitwise.band(e, 0xFFFFFFFFFFFF))

      {:ok, <<most::64, least::64>>}
    else
      _ -> :error
    end
  end

  defp hex(""), do: nil

  defp hex(text) do
    {sign, digits} =
      case text do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        _ -> {1, text}
      end

    with true <- digits != "" and Regex.match?(~r/\A[0-9a-fA-F]+\z/, digits),
         value = sign * String.to_integer(digits, 16),
         true <- value in -0x8000000000000000..0x7FFFFFFFFFFFFFFF do
      value
    else
      _ -> nil
    end
  end

  # ---- options ----

  defp parse_options(reader, s) do
    reader = Reader.skip_whitespace(reader)
    options_loop(reader, s)
  end

  defp options_loop(reader, s) do
    if Reader.can_read?(reader) and Reader.peek(reader) != ?] do
      reader = Reader.skip_whitespace(reader)
      start = reader.cursor
      {key, reader} = Reader.read_string(reader)
      check_option!(s, key, reader, start)
      reader = Reader.skip_whitespace(reader)

      unless Reader.at?(reader, ?=),
        do:
          Error.fail_at!(
            "argument.entity.options.valueless",
            [key],
            Reader.set_cursor(reader, start)
          )

      reader = reader |> Reader.skip() |> Reader.skip_whitespace()
      {s, reader} = option(key, reader, s)
      reader = Reader.skip_whitespace(reader)

      cond do
        not Reader.can_read?(reader) -> options_loop(reader, s)
        Reader.peek(reader) == ?, -> options_loop(Reader.skip(reader), s)
        Reader.peek(reader) == ?] -> finish_options(reader, s)
        true -> Error.fail_at!("argument.entity.options.unterminated", [], reader)
      end
    else
      finish_options(reader, s)
    end
  end

  defp finish_options(reader, s) do
    if Reader.can_read?(reader),
      do: {s, Reader.skip(reader)},
      else: Error.fail_at!("argument.entity.options.unterminated", [], reader)
  end

  @options ~w(name distance level x y z dx dy dz x_rotation y_rotation limit sort gamemode team type tag nbt scores advancements predicate)

  defp check_option!(s, key, reader, start) do
    usable =
      case key do
        "name" -> invertable_any?(s, :name)
        "distance" -> s.distance == nil
        "level" -> s.level == nil
        "x" -> s.x == nil
        "y" -> s.y == nil
        "z" -> s.z == nil
        "dx" -> s.dx == nil
        "dy" -> s.dy == nil
        "dz" -> s.dz == nil
        "x_rotation" -> s.rot_x == nil
        "y_rotation" -> s.rot_y == nil
        "limit" -> not s.current_entity and not Map.has_key?(s.options, :limit)
        "sort" -> not s.current_entity and not Map.has_key?(s.options, :sort)
        "gamemode" -> invertable_any?(s, :gamemode)
        "team" -> invertable_any?(s, :team)
        "type" -> invertable_any?(s, :type)
        "scores" -> not Map.has_key?(s.options, :scores)
        "advancements" -> not Map.has_key?(s.options, :advancements)
        key when key in @options -> true
        _ -> nil
      end

    case usable do
      true ->
        :ok

      false ->
        Error.fail_at!(
          "argument.entity.options.inapplicable",
          [key],
          Reader.set_cursor(reader, start)
        )

      nil ->
        Error.fail_at!("argument.entity.options.unknown", [key], Reader.set_cursor(reader, start))
    end
  end

  # InvertableSetOptionState: none, a single positive element, or negative elements/tags.
  defp state(s, option), do: Map.get(s.options, option, {:none, MapSet.new()})
  defp invertable_any?(s, option), do: elem(state(s, option), 0) != :single
  defp can_parse_element?(s, option, true), do: elem(state(s, option), 0) != :single
  defp can_parse_element?(s, option, false), do: elem(state(s, option), 0) == :none

  defp mark(s, option, inverted, tag \\ nil) do
    {_, tags} = state(s, option)
    tags = if tag, do: MapSet.put(tags, tag), else: tags
    put_in(s.options[option], {if(inverted or tag, do: :multiple, else: :single), tags})
  end

  defp invert(reader) do
    reader = Reader.skip_whitespace(reader)

    if Reader.at?(reader, ?!),
      do: {true, reader |> Reader.skip() |> Reader.skip_whitespace()},
      else: {false, reader}
  end

  defp tag?(reader) do
    reader = Reader.skip_whitespace(reader)

    if Reader.at?(reader, ?#),
      do: {true, reader |> Reader.skip() |> Reader.skip_whitespace()},
      else: {false, reader}
  end

  defp rollback!(key, args, reader, start),
    do: Error.fail_at!(key, args, Reader.set_cursor(reader, start))

  defp add(s, predicate), do: %{s | predicates: s.predicates ++ [predicate]}

  defp option("name", reader, s) do
    start = reader.cursor
    {inverted, reader} = invert(reader)
    {name, reader} = Reader.read_string(reader)

    unless can_parse_element?(s, :name, inverted),
      do: rollback!("argument.entity.options.inapplicable", ["name"], reader, start)

    {s |> mark(:name, inverted) |> add({:name, name, inverted}), reader}
  end

  defp option("distance", reader, s) do
    start = reader.cursor
    {range, reader} = Range.doubles(reader)

    if Enum.any?([range.min, range.max], &(&1 != nil and Range.below_zero?(&1))),
      do: rollback!("argument.entity.options.distance.negative", [], reader, start)

    {%{s | distance: range, world_limited: true}, reader}
  end

  defp option("level", reader, s) do
    start = reader.cursor
    {range, reader} = Range.ints(reader)

    if Enum.any?([range.min, range.max], &(&1 != nil and &1 < 0)),
      do: rollback!("argument.entity.options.level.negative", [], reader, start)

    {%{s | level: range, includes_entities: false}, reader}
  end

  defp option(axis, reader, s) when axis in ~w(x y z dx dy dz) do
    {value, reader} = Reader.read_double(reader)
    {Map.put(%{s | world_limited: true}, String.to_atom(axis), value), reader}
  end

  defp option("x_rotation", reader, s) do
    {range, reader} = Range.floats(reader)
    {%{s | rot_x: range}, reader}
  end

  defp option("y_rotation", reader, s) do
    {range, reader} = Range.floats(reader)
    {%{s | rot_y: range}, reader}
  end

  defp option("limit", reader, s) do
    start = reader.cursor
    {count, reader} = Reader.read_int(reader)
    if count < 1, do: rollback!("argument.entity.options.limit.toosmall", [], reader, start)
    {%{s | max_results: count, options: Map.put(s.options, :limit, true)}, reader}
  end

  defp option("sort", reader, s) do
    start = reader.cursor
    {name, reader} = Reader.read_unquoted_string(reader)

    order =
      case name do
        "nearest" -> :nearest
        "furthest" -> :furthest
        "random" -> :random
        "arbitrary" -> :arbitrary
        _ -> rollback!("argument.entity.options.sort.irreversible", [name], reader, start)
      end

    {%{s | order: order, options: Map.put(s.options, :sort, true)}, reader}
  end

  defp option("gamemode", reader, s) do
    start = reader.cursor
    {inverted, reader} = invert(reader)

    unless can_parse_element?(s, :gamemode, inverted),
      do: rollback!("argument.entity.options.inapplicable", ["gamemode"], reader, start)

    {name, reader} = Reader.read_unquoted_string(reader)

    unless name in ~w(survival creative adventure spectator),
      do: rollback!("argument.entity.options.mode.invalid", [name], reader, start)

    s = %{s | includes_entities: false} |> add({:gamemode, String.to_atom(name), inverted})
    {mark(s, :gamemode, inverted), reader}
  end

  defp option("team", reader, s) do
    start = reader.cursor
    {inverted, reader} = invert(reader)
    {team, reader} = Reader.read_unquoted_string(reader)

    unless can_parse_element?(s, :team, inverted),
      do: rollback!("argument.entity.options.inapplicable", ["team"], reader, start)

    {s |> add({:team, team, inverted}) |> mark(:team, inverted), reader}
  end

  defp option("type", reader, s) do
    start = reader.cursor
    {inverted, reader} = invert(reader)
    {tag, reader} = tag?(reader)

    if tag do
      unless invertable_any?(s, :type),
        do: rollback!("argument.entity.options.inapplicable", ["type"], reader, start)

      {id, reader} = Identifier.read(reader)
      {_, tags} = state(s, :type)

      if MapSet.member?(tags, id),
        do: rollback!("argument.entity.options.inapplicable", ["type"], reader, start)

      {s |> add({:type_tag, id, inverted}) |> mark(:type, inverted, id), reader}
    else
      unless can_parse_element?(s, :type, inverted),
        do: rollback!("argument.entity.options.inapplicable", ["type"], reader, start)

      {id, reader} = Identifier.read(reader)

      unless Registries.entry?("minecraft:entity_type", id),
        do: rollback!("argument.entity.options.type.invalid", [id], reader, start)

      s =
        if id == "minecraft:player" and not inverted, do: %{s | includes_entities: false}, else: s

      s = add(s, {:type, id, inverted})
      s = if inverted, do: s, else: %{s | type: id}
      {mark(s, :type, inverted), reader}
    end
  end

  defp option("tag", reader, s) do
    {inverted, reader} = invert(reader)
    {tag, reader} = Reader.read_unquoted_string(reader)
    {add(s, {:tag, tag, inverted}), reader}
  end

  defp option("scores", reader, s) do
    reader = reader |> Reader.expect(?{) |> Reader.skip_whitespace()
    {scores, reader} = scores(reader, %{})
    s = if scores == %{}, do: s, else: add(s, {:scores, scores})
    {%{s | options: Map.put(s.options, :scores, true)}, reader}
  end

  defp option("advancements", reader, s) do
    reader = reader |> Reader.expect(?{) |> Reader.skip_whitespace()
    {advancements, reader} = advancements(reader, %{})

    s =
      if advancements == %{},
        do: s,
        else: %{add(s, {:advancements, advancements}) | includes_entities: false}

    {%{s | options: Map.put(s.options, :advancements, true)}, reader}
  end

  defp option("predicate", reader, s) do
    {inverted, reader} = invert(reader)
    {id, reader} = Identifier.read(reader)
    {add(s, {:predicate, id, inverted}), reader}
  end

  defp option("nbt", reader, _s) do
    # SNBT (vanilla's packrat `TagParser`) is VMC-053g; the option stays pending.
    Error.throw!(Error.unsupported("Selector nbt= (SNBT) is not supported yet", reader))
  end

  defp scores(reader, acc) do
    if Reader.can_read?(reader) and Reader.peek(reader) != ?} do
      reader = Reader.skip_whitespace(reader)
      {name, reader} = Reader.read_unquoted_string(reader)
      reader = reader |> Reader.skip_whitespace() |> Reader.expect(?=) |> Reader.skip_whitespace()
      {range, reader} = Range.ints(reader)
      reader = Reader.skip_whitespace(reader)
      reader = if Reader.at?(reader, ?,), do: Reader.skip(reader), else: reader
      scores(reader, Map.put(acc, name, range))
    else
      {acc, Reader.expect(reader, ?})}
    end
  end

  defp advancements(reader, acc) do
    if Reader.can_read?(reader) and Reader.peek(reader) != ?} do
      reader = Reader.skip_whitespace(reader)
      {id, reader} = Identifier.read(reader)
      reader = reader |> Reader.skip_whitespace() |> Reader.expect(?=) |> Reader.skip_whitespace()

      {value, reader} =
        if Reader.at?(reader, ?{) do
          reader =
            reader |> Reader.skip_whitespace() |> Reader.expect(?{) |> Reader.skip_whitespace()

          {criteria, reader} = criteria(reader, %{})

          {criteria,
           reader |> Reader.skip_whitespace() |> Reader.expect(?}) |> Reader.skip_whitespace()}
        else
          Reader.read_boolean(reader)
        end

      reader = Reader.skip_whitespace(reader)
      reader = if Reader.at?(reader, ?,), do: Reader.skip(reader), else: reader
      advancements(reader, Map.put(acc, id, value))
    else
      {acc, Reader.expect(reader, ?})}
    end
  end

  defp criteria(reader, acc) do
    if Reader.can_read?(reader) and Reader.peek(reader) != ?} do
      reader = Reader.skip_whitespace(reader)
      {name, reader} = Reader.read_unquoted_string(reader)
      reader = reader |> Reader.skip_whitespace() |> Reader.expect(?=) |> Reader.skip_whitespace()
      {value, reader} = Reader.read_boolean(reader)
      reader = Reader.skip_whitespace(reader)
      reader = if Reader.at?(reader, ?,), do: Reader.skip(reader), else: reader
      criteria(reader, Map.put(acc, name, value))
    else
      {acc, reader}
    end
  end

  defp finalize(s) do
    s
    |> then(&if &1.rot_x, do: add(&1, {:rot_x, &1.rot_x}), else: &1)
    |> then(&if &1.rot_y, do: add(&1, {:rot_y, &1.rot_y}), else: &1)
    |> then(&if &1.level, do: add(&1, {:level, &1.level}), else: &1)
  end

  def self_selector?(s), do: s.current_entity

  # ---- resolution ----

  @doc """
  Players a selector picks for a source at `origin` (`EntitySelector.findEntities`):
  `players` are the online player maps, `self` the source's player map or nil.
  """
  def find(%__MODULE__{} = s, players, self, origin) do
    cond do
      s.player_name ->
        players
        |> Enum.filter(&(String.downcase(&1.name) == String.downcase(s.player_name)))
        |> Enum.take(1)

      s.uuid ->
        players |> Enum.filter(&(&1.uuid == s.uuid)) |> Enum.take(1)

      s.current_entity ->
        if self && matches?(s, self, origin), do: [self], else: []

      true ->
        position = {s.x || elem(origin, 0), s.y || elem(origin, 1), s.z || elem(origin, 2)}

        players
        |> Enum.filter(&matches?(s, &1, position))
        |> sort(s.order, position)
        |> Enum.take(s.max_results)
    end
  end

  defp matches?(s, player, position) do
    in_box?(s, player, position) and in_distance?(s, player, position) and
      Enum.all?(s.predicates, &predicate?(&1, player))
  end

  defp in_box?(%{dx: nil, dy: nil, dz: nil}, _player, _position), do: true

  defp in_box?(s, player, {x, y, z}) do
    {x0, x1} = span(s.dx || 0.0, x)
    {y0, y1} = span(s.dy || 0.0, y)
    {z0, z1} = span(s.dz || 0.0, z)
    # The player's hitbox (0.6 x 1.8, smaller when crouching is ignored) intersects the box.
    player.x + 0.3 > x0 and player.x - 0.3 < x1 and player.y + 1.8 > y0 and player.y < y1 and
      player.z + 0.3 > z0 and player.z - 0.3 < z1
  end

  defp span(delta, origin) when delta < 0, do: {origin + delta, origin + 1.0}
  defp span(delta, origin), do: {origin, origin + delta + 1.0}

  defp in_distance?(%{distance: nil}, _player, _position), do: true

  defp in_distance?(%{distance: range}, player, {x, y, z}) do
    squared = (player.x - x) ** 2 + (player.y - y) ** 2 + (player.z - z) ** 2
    Range.matches_squared?(range, squared)
  end

  defp predicate?(:alive, player), do: Map.get(player, :health, 20.0) > 0
  defp predicate?({:name, name, inverted}, player), do: player.name == name != inverted

  defp predicate?({:gamemode, mode, inverted}, player),
    do: game_mode(player) == mode != inverted

  defp predicate?({:team, team, inverted}, _player), do: team == "" != inverted
  defp predicate?({:type, type, inverted}, _player), do: type == "minecraft:player" != inverted

  defp predicate?({:type_tag, tag, inverted}, _player) do
    members = Registries.tag("minecraft:entity_type", tag) || []
    player = Valimc.Protocol.EntityTypes.id("minecraft:player")
    player in members != inverted
  end

  defp predicate?({:tag, "", inverted}, _player), do: not inverted
  defp predicate?({:tag, _tag, inverted}, _player), do: inverted
  defp predicate?({:scores, _}, _player), do: false
  defp predicate?({:advancements, _}, _player), do: false
  defp predicate?({:predicate, _, _}, _player), do: false

  defp predicate?({:level, range}, player),
    do: Range.matches?(range, get_in(player, [:progression, :experience, :level]) || 0)

  defp predicate?({:rot_x, range}, player),
    do: Range.rotation?(range, Map.get(player, :pitch, 0.0))

  defp predicate?({:rot_y, range}, player), do: Range.rotation?(range, Map.get(player, :yaw, 0.0))

  defp game_mode(%{game_mode: %{current: mode}}), do: mode
  defp game_mode(%{game_mode: mode}) when is_atom(mode), do: mode
  defp game_mode(_), do: nil

  defp sort(players, :arbitrary, _), do: players
  defp sort(players, :random, _), do: Enum.shuffle(players)
  defp sort(players, :nearest, position), do: Enum.sort_by(players, &squared(&1, position))

  defp sort(players, :furthest, position),
    do: Enum.sort_by(players, &squared(&1, position), :desc)

  defp squared(player, {x, y, z}),
    do: (player.x - x) ** 2 + (player.y - y) ** 2 + (player.z - z) ** 2
end
