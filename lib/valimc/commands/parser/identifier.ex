defmodule Valimc.Commands.Parser.Identifier do
  @moduledoc "Vanilla `Identifier.read` and `parse` for command arguments (VMC-053)."
  alias Valimc.Text.{Error, Reader}

  def allowed?(c), do: c in ?0..?9 or c in ?a..?z or c in [?_, ?:, ?/, ?., ?-]

  @doc "Reads `namespace:path` (the namespace defaults to `minecraft`) as a string."
  def read(reader) do
    start = reader.cursor
    {raw, reader} = Reader.take_while(reader, &allowed?/1)

    case parse(raw) do
      {:ok, id} -> {id, reader}
      :error -> Error.fail_at!("argument.id.invalid", [], Reader.set_cursor(reader, start))
    end
  end

  def parse(raw) do
    {namespace, path} =
      case :binary.split(raw, ":") do
        [path] -> {"minecraft", path}
        ["", path] -> {"minecraft", path}
        [namespace, path] -> {namespace, path}
      end

    if valid_namespace?(namespace) and valid_path?(path),
      do: {:ok, namespace <> ":" <> path},
      else: :error
  end

  defp valid_namespace?(".."), do: false

  defp valid_namespace?(namespace),
    do:
      namespace
      |> String.to_charlist()
      |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?z or &1 in [?_, ?., ?-]))

  defp valid_path?(path),
    do:
      path
      |> String.to_charlist()
      |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?z or &1 in [?_, ?., ?-, ?/]))
end
