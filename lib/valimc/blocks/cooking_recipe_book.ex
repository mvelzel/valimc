defmodule Valimc.Blocks.CookingRecipeBook do
  @moduledoc "Bounded native cooking display data, shared as immutable binaries; placement/autofill is separate."
  alias Valimc.Protocol.{Packets, Wire}
  use Valimc.Data.Facts, "crafting/cooking_book.json"

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
