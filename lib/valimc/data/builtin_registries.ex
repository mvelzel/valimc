defmodule Valimc.Data.BuiltinRegistries do
  @moduledoc """
  Network ids of the built-in registries that item component values name (sound
  events, attributes, villager types, block entity types, consume effect types),
  generated from the pinned jar (`ItemMetadata`).
  """
  use Valimc.Data.Facts, "protocol/builtin_registries.json"

  @names Map.new(@facts["registries"], fn {registry, entries} ->
           {registry, List.to_tuple(entries)}
         end)
  @ids Map.new(@facts["registries"], fn {registry, entries} ->
         {registry, entries |> Enum.with_index() |> Map.new()}
       end)

  def registry?(registry), do: is_map_key(@names, registry)
  def id(registry, name), do: @ids[registry][name]

  def name(registry, id) do
    case @names[registry] do
      names when is_integer(id) and id >= 0 and id < tuple_size(names) -> elem(names, id)
      _ -> nil
    end
  end
end
