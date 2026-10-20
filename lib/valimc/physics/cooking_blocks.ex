defmodule Valimc.Physics.CookingBlocks do
  @moduledoc "Pinned furnace-family kinds, facing-preserving light states and empty placement."
  alias Valimc.Physics.ChestPlacement
  alias Valimc.Protocol.Data
  @path Path.expand("../../../priv/physics/cooking_blocks.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @kinds {:furnace, :smoker, :blast_furnace}
  @states Map.new(@facts["states"], fn row -> {row["state"], elem(@kinds, row["kind"])} end)
  @lit Map.new(@facts["states"], fn row ->
         pair =
           Map.new(
             Enum.filter(@facts["states"], fn other ->
               other["kind"] == row["kind"] and other["facing"] == row["facing"]
             end),
             &{&1["lit"], &1["state"]}
           )

         {row["state"], pair}
       end)
  @placements @facts["placements"]
              |> Enum.map(fn table ->
                Map.new(table, fn {heading, state} -> {String.to_integer(heading), state} end)
              end)
              |> List.to_tuple()
  @items Map.new(Tuple.to_list(@kinds), fn kind -> {Data.item(Atom.to_string(kind)), kind} end)
  unless Valimc.Version.stamped?(@facts) and
           map_size(@states) == 24 and tuple_size(@placements) == 3 and
           Enum.all?(Tuple.to_list(@placements), fn table ->
             Enum.sort(Map.keys(table)) == [2, 3, 4, 5] and
               Enum.all?(table, fn {_, state} -> Map.has_key?(@states, state) end)
           end),
         do: raise("Wrong native cooking-block facts")

  def kind(state), do: Map.get(@states, state)
  def kind_for_item(item), do: Map.get(@items, item)

  def lit(state, value) when is_boolean(value) do
    case @lit do
      %{^state => %{^value => result}} -> {:ok, result}
      _ -> {:error, :invalid_cooking_state}
    end
  end

  def lit(_, _), do: {:error, :invalid_cooking_state}

  def placement(kind, yaw) when kind in [:furnace, :smoker, :blast_furnace] do
    with {:ok, heading} <- ChestPlacement.horizontal(yaw) do
      index =
        case kind do
          :furnace -> 0
          :smoker -> 1
          :blast_furnace -> 2
        end

      {:ok, Map.fetch!(elem(@placements, index), heading)}
    else
      _ -> {:error, :invalid_cooking_yaw}
    end
  end

  def placement(_, _), do: {:error, :invalid_cooking_kind}
end
