defmodule Valimc.Command.ItemInput do
  @moduledoc """
  The `item_stack` argument (VMC-053): vanilla `ItemParser`, `id` and
  `id[component=value,!component]`; `item_predicate` is `Valimc.Command.ItemPredicate`.
  Component values are SNBT (`Valimc.Command.Snbt`) decoded as the data format
  reads them (`Valimc.Protocol.ItemData.decode_component/2`); components
  ValiMC cannot represent are refused with a ValiMC message instead of being
  approximated.
  """
  alias Valimc.Command.{Error, Identifier, Reader, Registries}

  defstruct [:item, :item_id, components: %{}, removed: MapSet.new()]

  def parse_stack(reader) do
    start = reader.cursor
    {id, reader} = Identifier.read(reader)

    item_id =
      Registries.item_id(id) ||
        Error.fail_at!("argument.item.id.invalid", [id], Reader.set_cursor(reader, start))

    input = %__MODULE__{item: id, item_id: item_id}
    if Reader.at?(reader, ?[), do: components(reader, input), else: {input, reader}
  end

  # Vanilla `ItemParser.readComponents`.
  defp components(reader, input) do
    reader = Reader.expect(reader, ?[)
    {input, reader} = component_loop(reader, input, MapSet.new())
    {input, Reader.expect(reader, ?])}
  end

  defp component_loop(reader, input, visited) do
    if Reader.can_read?(reader) and Reader.peek(reader) != ?] do
      reader = Reader.skip_whitespace(reader)

      {input, reader, visited} =
        if Reader.at?(reader, ?!) do
          {id, reader} = component_type(Reader.skip(reader))
          visited = visit(visited, id)

          {%{input | removed: MapSet.put(input.removed, id)}, Reader.skip_whitespace(reader),
           visited}
        else
          {id, reader} = component_type(reader)
          visited = visit(visited, id)

          reader =
            reader |> Reader.skip_whitespace() |> Reader.expect(?=) |> Reader.skip_whitespace()

          {value, reader} = component_value(reader, id)

          {%{input | components: Map.put(input.components, id, value)},
           Reader.skip_whitespace(reader), visited}
        end

      if Reader.at?(reader, ?,) do
        reader = reader |> Reader.skip() |> Reader.skip_whitespace()

        unless Reader.can_read?(reader),
          do: Error.fail_at!("arguments.item.component.expected", [], reader)

        component_loop(reader, input, visited)
      else
        {input, reader}
      end
    else
      {input, reader}
    end
  end

  defp visit(visited, id) do
    if MapSet.member?(visited, id), do: Error.fail!("arguments.item.component.repeated", [id])
    MapSet.put(visited, id)
  end

  defp component_type(reader) do
    unless Reader.can_read?(reader),
      do: Error.fail_at!("arguments.item.component.expected", [], reader)

    start = reader.cursor
    {id, reader} = Identifier.read(reader)

    if Valimc.Command.Facts.item_component?(id),
      do: {id, reader},
      else:
        Error.fail_at!("arguments.item.component.unknown", [id], Reader.set_cursor(reader, start))
  end

  # The SNBT value, then the component's codec (`readComponent`).
  defp component_value(reader, id) do
    start = reader.cursor
    {tag, after_value} = Valimc.Command.Snbt.parse(reader)

    case Valimc.Protocol.ItemData.decode_component(id, tag) do
      {:ok, value} ->
        {value, after_value}

      {:error, message} ->
        Error.fail_at!(
          "arguments.item.component.malformed",
          [id, message],
          Reader.set_cursor(after_value, start)
        )

      :unsupported ->
        Error.throw!(
          Error.unsupported(
            "The item component #{id} is not supported yet",
            Reader.set_cursor(after_value, start)
          )
        )
    end
  end
end
