defmodule Valimc.Commands.Parser.BlockInput do
  @moduledoc """
  Vanilla `BlockStateParser` (VMC-053): `block_state` (`id[prop=value]`) and
  `block_predicate` (also `#tag[prop=value]`), with vanilla's errors and cursors.
  Block-entity data (`{...}`) is SNBT (`Valimc.Text.Snbt`).
  """
  alias Valimc.Text.{Error, Reader}
  alias Valimc.Text.Identifier
  alias Valimc.Protocol.Registries
  alias Valimc.Data.Blocks

  defstruct [:block, :state, :tag, properties: %{}, vague: %{}, nbt: nil]

  def parse_state(reader), do: parse(reader, false)
  def parse_predicate(reader), do: parse(reader, true)

  defp parse(reader, testing) do
    cursor = reader.cursor

    try do
      {input, reader} =
        if Reader.at?(reader, ?#) do
          unless testing, do: Error.fail_at!("argument.block.tag.disallowed", [], reader)
          {input, reader} = read_tag(reader)

          if Reader.at?(reader, ?[),
            do: read_vague(Reader.skip(reader), input),
            else: {input, reader}
        else
          {input, reader} = read_block(reader)

          if Reader.at?(reader, ?[),
            do: read_properties(Reader.skip(reader), input),
            else: {input, reader}
        end

      if Reader.at?(reader, ?{) do
        {nbt, reader} = Valimc.Text.Snbt.parse_compound(reader)
        {%{input | nbt: nbt}, reader}
      else
        {input, reader}
      end
    catch
      {:command_syntax, error} ->
        _ = cursor
        Error.throw!(error)
    end
  end

  defp read_block(reader) do
    start = reader.cursor
    {id, reader} = Identifier.read(reader)

    unless Registries.entry?("minecraft:block", id),
      do: Error.fail_at!("argument.block.id.invalid", [id], Reader.set_cursor(reader, start))

    "minecraft:" <> name = id
    {%__MODULE__{block: name, state: Blocks.default_state(name)}, reader}
  end

  defp read_tag(reader) do
    start = reader.cursor
    reader = Reader.expect(reader, ?#)
    {id, reader} = Identifier.read(reader)

    case Registries.tag("minecraft:block", id) do
      nil -> Error.fail_at!("arguments.block.tag.unknown", [id], Reader.set_cursor(reader, start))
      members -> {%__MODULE__{tag: {id, MapSet.new(members)}}, reader}
    end
  end

  defp read_properties(reader, input) do
    reader = Reader.skip_whitespace(reader)

    definitions =
      Map.new(Blocks.definitions(input.block), fn {name, values} ->
        {name, Tuple.to_list(values)}
      end)

    properties_loop(reader, input, definitions)
  end

  defp properties_loop(reader, input, definitions) do
    id = "minecraft:" <> input.block

    if Reader.can_read?(reader) and Reader.peek(reader) != ?] do
      reader = Reader.skip_whitespace(reader)
      key_start = reader.cursor
      {key, reader} = Reader.read_string(reader)

      values =
        Map.get(definitions, key) ||
          Error.fail_at!(
            "argument.block.property.unknown",
            [id, key],
            Reader.set_cursor(reader, key_start)
          )

      if Map.has_key?(input.properties, key),
        do:
          Error.fail_at!(
            "argument.block.property.duplicate",
            [key, id],
            Reader.set_cursor(reader, key_start)
          )

      reader = Reader.skip_whitespace(reader)

      unless Reader.at?(reader, ?=),
        do: Error.fail_at!("argument.block.property.novalue", [key, id], reader)

      reader = reader |> Reader.skip() |> Reader.skip_whitespace()
      start = reader.cursor
      {value, reader} = Reader.read_string(reader)

      unless value in values,
        do:
          Error.fail_at!(
            "argument.block.property.invalid",
            [id, value, key],
            Reader.set_cursor(reader, start)
          )

      input = %{input | properties: Map.put(input.properties, key, value)}

      input = %{
        input
        | state:
            Blocks.state(
              input.block,
              Map.merge(Map.new(Blocks.properties(input.state)), %{key => value})
            )
      }

      reader = Reader.skip_whitespace(reader)

      cond do
        not Reader.can_read?(reader) -> properties_loop(reader, input, definitions)
        Reader.peek(reader) == ?, -> properties_loop(Reader.skip(reader), input, definitions)
        Reader.peek(reader) == ?] -> close(reader, input)
        true -> Error.fail_at!("argument.block.property.unclosed", [], reader)
      end
    else
      close(reader, input)
    end
  end

  defp close(reader, input) do
    if Reader.can_read?(reader),
      do: {input, Reader.skip(reader)},
      else: Error.fail_at!("argument.block.property.unclosed", [], reader)
  end

  defp read_vague(reader, input) do
    reader = Reader.skip_whitespace(reader)
    vague_loop(reader, input, -1)
  end

  defp vague_loop(reader, input, value_start) do
    if Reader.can_read?(reader) and Reader.peek(reader) != ?] do
      # Vanilla names the (empty) block id in tag property errors.
      id = "minecraft:"
      reader = Reader.skip_whitespace(reader)
      key_start = reader.cursor
      {key, reader} = Reader.read_string(reader)

      if Map.has_key?(input.vague, key),
        do:
          Error.fail_at!(
            "argument.block.property.duplicate",
            [key, id],
            Reader.set_cursor(reader, key_start)
          )

      reader = Reader.skip_whitespace(reader)

      unless Reader.at?(reader, ?=),
        do:
          Error.fail_at!(
            "argument.block.property.novalue",
            [key, id],
            Reader.set_cursor(reader, key_start)
          )

      reader = reader |> Reader.skip() |> Reader.skip_whitespace()
      value_start = reader.cursor
      {value, reader} = Reader.read_string(reader)
      input = %{input | vague: Map.put(input.vague, key, value)}
      reader = Reader.skip_whitespace(reader)

      cond do
        not Reader.can_read?(reader) -> vague_loop(reader, input, value_start)
        Reader.peek(reader) == ?, -> vague_loop(Reader.skip(reader), input, -1)
        Reader.peek(reader) == ?] -> {input, Reader.skip(reader)}
        true -> Error.fail_at!("argument.block.property.unclosed", [], reader)
      end
    else
      if Reader.can_read?(reader) do
        {input, Reader.skip(reader)}
      else
        reader = if value_start >= 0, do: Reader.set_cursor(reader, value_start), else: reader
        Error.fail_at!("argument.block.property.unclosed", [], reader)
      end
    end
  end

  @doc "Whether a block state satisfies a `block_predicate` input (properties by name)."
  def matches?(%__MODULE__{tag: nil} = input, state) do
    Blocks.block_id(state) == Blocks.block_id(input.state) and
      Enum.all?(input.properties, fn {key, value} ->
        List.keyfind(Blocks.properties(state), key, 0) == {key, value}
      end)
  end

  def matches?(%__MODULE__{tag: {_, members}} = input, state) do
    MapSet.member?(members, Blocks.block_id(state)) and
      Enum.all?(input.vague, fn {key, value} ->
        case List.keyfind(Blocks.properties(state), key, 0) do
          nil -> false
          {_, actual} -> actual == value
        end
      end)
  end
end
