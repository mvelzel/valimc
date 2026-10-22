defmodule Valimc.Text.Selector do
  @moduledoc """
  Vanilla entity selectors (VMC-053): `EntitySelectorParser` and its options with
  vanilla's errors and cursors, and resolution against ValiMC's players.

  Only players are selectable entities today; `@e`, `@n` and `type=` therefore
  resolve to players, and non-player predicates select nothing.
  """
  alias Valimc.Text.{Error, Reader}
  alias Valimc.Text.{Identifier, Range}
  alias Valimc.Protocol.Registries

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
      case Valimc.Data.UUID.parse(name) do
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

  defp option("nbt", reader, s) do
    {inverted, reader} = invert(reader)
    {tag, reader} = Valimc.Text.Snbt.parse_compound(reader)
    {add(s, {:nbt, tag, inverted}), reader}
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
end
