defmodule Valimc.Commands.Parser.Arguments do
  @moduledoc """
  Argument types by vanilla parser ID (VMC-053), parsed with vanilla's syntax and
  errors. Properties are the generated ones from `priv/commands/tree.json`.
  `supported/0` lists the parsers ValiMC parses; `Valimc.Commands` refuses to
  compile a handler whose path needs any other.
  """
  alias Valimc.Data.Float32
  alias Valimc.Commands.Parser.{BlockInput, Coordinates, ItemInput}
  alias Valimc.Text.{Identifier, Selector}
  alias Valimc.Text.{Error, Reader}
  alias Valimc.Protocol.Registries

  @int_min -2_147_483_648
  @int_max 2_147_483_647

  @supported ~w(brigadier:bool brigadier:integer brigadier:long brigadier:float brigadier:double
    brigadier:string minecraft:entity minecraft:gamemode minecraft:vec3 minecraft:vec2 minecraft:block_pos
    minecraft:rotation minecraft:entity_anchor minecraft:time minecraft:message
    minecraft:item_stack minecraft:item_predicate minecraft:block_state minecraft:block_predicate
    minecraft:resource minecraft:resource_or_tag minecraft:resource_location
    minecraft:nbt_compound_tag minecraft:nbt_tag minecraft:component minecraft:particle
    minecraft:dialog minecraft:column_pos minecraft:dimension minecraft:game_profile minecraft:resource_or_tag_key
    minecraft:feature minecraft:resource_key minecraft:template_rotation minecraft:template_mirror
    minecraft:slot_source)

  @configured_features Valimc.Worldgen.Facts.features()

  def supported, do: @supported

  def parse(%{parser: parser, properties: props}, reader, source),
    do: parse(parser, props, reader, source)

  def parse("brigadier:bool", _props, reader, _source), do: Reader.read_boolean(reader)

  def parse("brigadier:integer", props, reader, _source),
    do: bounded(reader, :int, props["min"] || @int_min, props["max"] || @int_max, "integer")

  def parse("brigadier:long", props, reader, _source),
    do:
      bounded(
        reader,
        :long,
        props["min"] || -9_223_372_036_854_775_808,
        props["max"] || 9_223_372_036_854_775_807,
        "long"
      )

  def parse("brigadier:float", props, reader, _source),
    do: bounded(reader, :float, float32(props["min"]), float32(props["max"]), "float")

  def parse("brigadier:double", props, reader, _source),
    do: bounded(reader, :double, props["min"], props["max"], "double")

  def parse("brigadier:string", %{"type" => "word"}, reader, _source),
    do: Reader.read_unquoted_string(reader)

  def parse("brigadier:string", %{"type" => "phrase"}, reader, _source),
    do: Reader.read_string(reader)

  def parse("brigadier:string", %{"type" => "greedy"}, reader, _source),
    do: {Reader.remaining(reader), Reader.set_cursor(reader, reader.size)}

  def parse("minecraft:entity", props, reader, source) do
    {selector, after_selector} = Selector.parse(reader, allow_selectors?(source))
    single = props["amount"] == "single"
    players_only = props["type"] == "players"
    at_input_start = Reader.set_cursor(after_selector, 0)

    cond do
      selector.max_results > 1 and single and players_only ->
        Error.fail_at!("argument.player.toomany", [], at_input_start)

      selector.max_results > 1 and single ->
        Error.fail_at!("argument.entity.toomany", [], at_input_start)

      selector.includes_entities and players_only and not selector.current_entity ->
        Error.fail_at!("argument.player.entities", [], at_input_start)

      true ->
        {selector, after_selector}
    end
  end

  # `GameProfileArgument`: a selector of players only, or a name up to the next space.
  def parse("minecraft:game_profile", _props, reader, source) do
    if Reader.at?(reader, ?@) do
      {selector, after_selector} = Selector.parse(reader, allow_selectors?(source))

      if selector.includes_entities,
        do: Error.fail_at!("argument.player.entities", [], after_selector)

      {{:selector, selector}, after_selector}
    else
      {name, reader} = Reader.take_while(reader, &(&1 != ?\s))
      {{:name, name}, reader}
    end
  end

  def parse("minecraft:gamemode", _props, reader, _source) do
    {name, reader} = Reader.read_unquoted_string(reader)

    if name in ~w(survival creative adventure spectator),
      do: {String.to_atom(name), reader},
      else: Error.fail_at!("argument.gamemode.invalid", [name], reader)
  end

  def parse("minecraft:vec3", _props, reader, _source), do: Coordinates.vec3(reader)
  def parse("minecraft:vec2", _props, reader, _source), do: Coordinates.vec2(reader)
  def parse("minecraft:block_pos", _props, reader, _source), do: Coordinates.block_pos(reader)
  def parse("minecraft:rotation", _props, reader, _source), do: Coordinates.rotation(reader)

  def parse("minecraft:entity_anchor", _props, reader, _source) do
    start = reader.cursor
    {name, reader} = Reader.read_unquoted_string(reader)

    case name do
      "feet" -> {:feet, reader}
      "eyes" -> {:eyes, reader}
      _ -> Error.fail_at!("argument.anchor.invalid", [name], Reader.set_cursor(reader, start))
    end
  end

  def parse("minecraft:time", props, reader, _source) do
    {value, reader} = Reader.read_float(reader)
    {unit, reader} = Reader.read_unquoted_string(reader)
    factor = %{"d" => 24_000, "s" => 20, "t" => 1, "" => 1}[unit]
    unless factor, do: Error.fail_at!("argument.time.invalid_unit", [], reader)
    ticks = java_round(value, factor)
    minimum = props["min"] || 0

    if ticks < minimum,
      do: Error.fail_at!("argument.time.tick_count_too_low", [minimum, ticks], reader),
      else: {ticks, reader}
  end

  def parse("minecraft:message", _props, reader, source) do
    if Reader.remaining_length(reader) > 256,
      do: Error.fail!("argument.message.too_long", [Reader.remaining_length(reader), 256])

    text = Reader.remaining(reader)

    if allow_selectors?(source) do
      offset = reader.cursor
      {parts, reader} = message_parts(reader, offset, [])
      {{:message, text, parts}, reader}
    else
      {{:message, text, []}, Reader.set_cursor(reader, reader.size)}
    end
  end

  def parse("minecraft:item_stack", _props, reader, _source), do: ItemInput.parse_stack(reader)

  def parse("minecraft:item_predicate", _props, reader, _source),
    do: Valimc.Commands.Parser.ItemPredicate.parse(reader)

  def parse("minecraft:block_state", _props, reader, _source), do: BlockInput.parse_state(reader)

  def parse("minecraft:block_predicate", _props, reader, _source),
    do: BlockInput.parse_predicate(reader)

  def parse("minecraft:resource", %{"registry" => registry}, reader, _source) do
    {id, reader} = Identifier.read(reader)

    if Registries.entry?(registry, id),
      do: {id, reader},
      else: Error.fail_at!("argument.resource.not_found", [id, registry], reader)
  end

  def parse("minecraft:resource_or_tag", %{"registry" => registry}, reader, _source) do
    if Reader.at?(reader, ?#) do
      {id, after_id} = Identifier.read(Reader.skip(reader))

      case Registries.tag(registry, id) do
        nil ->
          Error.fail_at!("argument.resource_tag.not_found", [id, registry], after_id)

        members ->
          {{:tag, id, members}, after_id}
      end
    else
      {id, reader} = Identifier.read(reader)

      if Registries.entry?(registry, id),
        do: {{:resource, id}, reader},
        else: Error.fail_at!("argument.resource.not_found", [id, registry], reader)
    end
  end

  def parse("minecraft:resource_location", _props, reader, _source), do: Identifier.read(reader)

  # `ResourceKeyArgument`: any identifier, checked when the command runs.
  def parse("minecraft:resource_key", _props, reader, _source), do: Identifier.read(reader)

  # `ResourceOrIdArgument.feature`: a configured feature's id, or an inline one
  # (refused).
  def parse("minecraft:feature", _props, reader, _source) do
    {id, after_id} = Identifier.read(reader)

    # The grammar's identifier rule must read something; otherwise the input is
    # an inline value, which the feature codec needs as a compound.
    if after_id.cursor == reader.cursor do
      {tag, after_tag} = Valimc.Text.Snbt.parse(reader)

      case tag do
        {:compound, _} ->
          Error.throw!(Error.unsupported("Inline features are not supported yet", after_tag))

        _ ->
          Error.fail_at!(
            "argument.resource_or_id.failed_to_parse",
            ["Not a map: " <> Valimc.Text.Snbt.to_string(tag)],
            after_tag
          )
      end
    else
      if id in @configured_features,
        do: {id, after_id},
        else:
          Error.fail_at!(
            "argument.resource_or_id.no_such_element",
            [id, "minecraft:worldgen/feature"],
            after_id
          )
    end
  end

  # `TemplateRotationArgument` / `TemplateMirrorArgument`: an enum's name.
  def parse(parser, _props, reader, _source)
      when parser in ["minecraft:template_rotation", "minecraft:template_mirror"] do
    {name, after_name} = Reader.read_unquoted_string(reader)

    names =
      if parser == "minecraft:template_rotation",
        do: ~w(none clockwise_90 180 counterclockwise_90),
        else: ~w(none front_back left_right)

    if name in names,
      do: {name, after_name},
      else: Error.fail_at!("argument.enum.invalid", [name], after_name)
  end

  # `ResourceOrTagKeyArgument`: a key or `#tag`, checked only when the command runs.
  def parse("minecraft:resource_or_tag_key", _props, reader, _source) do
    if Reader.at?(reader, ?#) do
      {id, reader} = Identifier.read(Reader.skip(reader))
      {{:tag_key, id}, reader}
    else
      {id, reader} = Identifier.read(reader)
      {{:key, id}, reader}
    end
  end

  def parse("minecraft:nbt_compound_tag", _props, reader, _source),
    do: Valimc.Text.Snbt.parse_compound(reader)

  def parse("minecraft:nbt_tag", _props, reader, _source), do: Valimc.Text.Snbt.parse(reader)

  def parse("minecraft:slot_source", _props, reader, _source),
    do: Valimc.Commands.Items.parse_slots(reader)

  def parse("minecraft:particle", _props, reader, _source),
    do: Valimc.Commands.Parser.ParticleInput.parse(reader)

  def parse("minecraft:column_pos", _props, reader, _source), do: Coordinates.column_pos(reader)
  def parse("minecraft:dimension", _props, reader, _source), do: Identifier.read(reader)

  # `ResourceOrIdArgument.DialogArgument`: a registered dialog; inline dialogs are refused.
  def parse("minecraft:dialog", _props, reader, _source) do
    if Reader.can_read?(reader) and Reader.peek(reader) in [?{, ?[, ?", ?'] do
      {_tag, after_tag} = Valimc.Text.Snbt.parse(reader)
      Error.throw!(Error.unsupported("Inline dialogs are not supported yet", after_tag))
    else
      {id, after_id} = Identifier.read(reader)

      case Valimc.Protocol.Data.find_registry_id("minecraft:dialog", id) do
        nil ->
          Error.fail_at!(
            "argument.resource_or_id.no_such_element",
            [id, "minecraft:dialog"],
            after_id
          )

        network_id ->
          {{id, network_id}, after_id}
      end
    end
  end

  def parse("minecraft:component", _props, reader, _source) do
    start = reader.cursor
    {tag, after_tag} = Valimc.Text.Snbt.parse(reader)

    case Valimc.Text.Codec.decode(tag) do
      {:ok, component} ->
        {component, after_tag}

      {:error, message} ->
        Error.fail_at!(
          "argument.component.invalid",
          [message],
          Reader.set_cursor(after_tag, start)
        )
    end
  end

  defp bounded(reader, type, min, max, name) do
    start = reader.cursor
    {value, reader} = read(reader, type)
    at_start = Reader.set_cursor(reader, start)

    cond do
      min != nil and less?(value, min) ->
        Error.fail_at!("argument.#{name}.low", [arg(min, type), arg(value, type)], at_start)

      max != nil and less?(max, value) ->
        Error.fail_at!("argument.#{name}.big", [arg(max, type), arg(value, type)], at_start)

      true ->
        {value, reader}
    end
  end

  defp float32(nil), do: nil
  defp float32(value), do: Float32.round_or_infinity(value * 1.0)

  defp read(reader, :int), do: Reader.read_int(reader)
  defp read(reader, :long), do: Reader.read_long(reader)
  defp read(reader, :float), do: Reader.read_float(reader)
  defp read(reader, :double), do: Reader.read_double(reader)

  defp less?(:neg_infinity, b), do: b != :neg_infinity
  defp less?(_a, :neg_infinity), do: false
  defp less?(:infinity, _b), do: false
  defp less?(_a, :infinity), do: true
  defp less?(a, b), do: a < b

  defp arg(value, :float) when is_integer(value), do: {:float, value * 1.0}
  defp arg(value, :float), do: {:float, value}
  defp arg(value, :double) when is_integer(value), do: {:double, value * 1.0}
  defp arg(value, :double), do: {:double, value}
  defp arg(value, _), do: value

  # Java `Math.round(float * int)`: float arithmetic, then floor(x + 0.5) saturated to int.
  defp java_round(value, factor) do
    product = Float32.round_or_infinity(mul(value, factor))

    case product do
      :infinity ->
        @int_max

      :neg_infinity ->
        @int_min

      p ->
        p
        |> Kernel.+(0.5)
        |> Float32.round_or_infinity()
        |> floor()
        |> max(@int_min)
        |> min(@int_max)
    end
  end

  defp mul(value, _factor) when value in [:infinity, :neg_infinity], do: value
  defp mul(value, factor), do: value * factor

  defp message_parts(reader, offset, acc) do
    cond do
      not Reader.can_read?(reader) ->
        {Enum.reverse(acc), reader}

      Reader.peek(reader) == ?@ ->
        start = reader.cursor

        case Error.catching(fn -> Selector.parse(reader, true) end) do
          {:ok, {selector, after_selector}} ->
            part = {start - offset, after_selector.cursor - offset, selector}
            message_parts(after_selector, offset, [part | acc])

          {:error, error} ->
            if missing_or_unknown_type?(error),
              do: message_parts(Reader.set_cursor(reader, start + 1), offset, acc),
              else: Error.throw!(error)
        end

      true ->
        message_parts(Reader.skip(reader), offset, acc)
    end
  end

  defp missing_or_unknown_type?(%Error{message: {:compound, %{"translate" => {:string, key}}}}),
    do: key in ["argument.entity.selector.missing", "argument.entity.selector.unknown"]

  defp missing_or_unknown_type?(_), do: false

  @doc "Vanilla `COMMANDS_ENTITY_SELECTORS`: gamemasters (level 2) and above."
  def allow_selectors?(source), do: source.level >= 2
end
