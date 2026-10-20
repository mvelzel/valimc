defmodule Valimc.Command.ItemInput do
  @moduledoc """
  Item arguments (VMC-053): `item_stack` (vanilla `ItemParser`: `id` and
  `id[component=value,!component]`) and `item_predicate` (`id`, `#tag`, `*`).
  Component values are SNBT and wait for VMC-053g; inputs that carry them are
  refused with a ValiMC message instead of being approximated.
  """
  alias Valimc.Command.{Error, Identifier, Reader, Registries}

  defstruct [:item, :item_id, :tag, any: false, components: []]

  def parse_stack(reader) do
    start = reader.cursor
    {id, reader} = Identifier.read(reader)

    item_id =
      Registries.item_id(id) ||
        Error.fail_at!("argument.item.id.invalid", [id], Reader.set_cursor(reader, start))

    input = %__MODULE__{item: id, item_id: item_id}
    if Reader.at?(reader, ?[), do: components(reader, input), else: {input, reader}
  end

  # Vanilla `readComponents`; any component entry needs SNBT (VMC-053g).
  defp components(reader, input) do
    reader = Reader.expect(reader, ?[)

    if Reader.can_read?(reader) and Reader.peek(reader) != ?] do
      reader = Reader.skip_whitespace(reader)

      {removal, reader} =
        if Reader.at?(reader, ?!), do: {true, Reader.skip(reader)}, else: {false, reader}

      unless Reader.can_read?(reader),
        do: Error.fail_at!("arguments.item.component.expected", [], reader)

      start = reader.cursor
      {id, reader} = Identifier.read(reader)

      unless Registries.component?(id),
        do:
          Error.fail_at!(
            "arguments.item.component.unknown",
            [id],
            Reader.set_cursor(reader, start)
          )

      reader =
        if removal,
          do: reader,
          else:
            reader |> Reader.skip_whitespace() |> Reader.expect(?=) |> Reader.skip_whitespace()

      Error.throw!(Error.unsupported("Item components are not supported yet", reader))
    else
      {input, Reader.expect(reader, ?])}
    end
  end

  def parse_predicate(reader) do
    start = reader.cursor

    {input, reader} =
      cond do
        Reader.at?(reader, ?*) ->
          {%__MODULE__{any: true}, Reader.skip(reader)}

        Reader.at?(reader, ?#) ->
          {id, after_id} = Identifier.read(Reader.skip(reader))

          case Registries.tag("minecraft:item", id) do
            nil ->
              Error.fail_at!(
                "arguments.item.tag.unknown",
                [id],
                after_id
              )

            members ->
              {%__MODULE__{tag: {id, MapSet.new(members)}}, after_id}
          end

        true ->
          {id, after_id} = Identifier.read(reader)

          case Registries.item_id(id) do
            nil ->
              Error.fail_at!("argument.item.id.invalid", [id], Reader.set_cursor(after_id, start))

            item_id ->
              {%__MODULE__{item: id, item_id: item_id}, after_id}
          end
      end

    if Reader.at?(reader, ?[),
      do: Error.throw!(Error.unsupported("Item components are not supported yet", reader)),
      else: {input, reader}
  end

  @doc "Whether an item stack matches a parsed `item_predicate`."
  def matches?(%__MODULE__{any: true}, _stack), do: true
  def matches?(%__MODULE__{tag: {_, members}}, stack), do: MapSet.member?(members, stack.item_id)
  def matches?(%__MODULE__{item_id: id}, stack), do: stack.item_id == id
end
