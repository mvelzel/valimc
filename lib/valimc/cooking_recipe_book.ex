defmodule Valimc.CookingRecipeBook do
  @moduledoc "Bounded native cooking display data, shared as immutable binaries; placement/autofill is separate."
  alias Valimc.Protocol.{Packets, Wire}
  @path Path.expand("../../priv/crafting/cooking_book.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  unless Valimc.Version.stamped?(@facts, ~w(version server_sha1)),
    do: raise("Wrong cooking recipe book facts")

  @rows @facts["entries"]
        |> Enum.with_index()
        |> Map.new(fn {row, index} ->
          {row["recipe"],
           %{
             index: index,
             quiet: Base.decode16!(row["quiet"], case: :lower),
             notify: Base.decode16!(row["notify"], case: :lower)
           }}
        end)

  def packet(%MapSet{} = recipes, replace?, notify?)
      when is_boolean(replace?) and is_boolean(notify?) do
    true = MapSet.size(recipes) <= 107
    rows = recipes |> Enum.map(&Map.fetch!(@rows, &1)) |> Enum.sort_by(& &1.index)
    entries = Enum.map(rows, fn row -> if notify?, do: row.notify, else: row.quiet end)

    Packets.packet("recipe_book_add", [
      Wire.varint(length(rows)),
      entries,
      <<if(replace?, do: 1, else: 0)>>
    ])
  end
end
