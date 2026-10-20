defmodule Valimc.Physics.Placement do
  @moduledoc """
  Pure native placement candidates; owners still admit geometry, writes and
  consumption. The placed state comes from the item's block behaviour
  (`Valimc.Block`); this module owns the generated placement facts.
  """
  @chest_item Valimc.Protocol.Data.item("chest")
  @cooking_items Enum.map(~w(furnace smoker blast_furnace), &Valimc.Protocol.Data.item/1)
  @facing_items [@chest_item | @cooking_items]
  @path Path.expand("../../../priv/physics/placement.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count Valimc.Registry.Blocks.state_count()
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count,
         do: raise("Wrong placement catalog version")

  @replace Base.decode16!(@facts["replaceability"], case: :lower)
  @plain Map.new(@facts["plain"], fn {item, state} -> {String.to_integer(item), state} end)
  @slabs Map.new(@facts["slabs"], fn row -> {row["item"], List.to_tuple(row["states"])} end)
  @pillars Map.new(@facts["pillars"], fn row -> {row["item"], List.to_tuple(row["states"])} end)
  @slab_states @facts["slabs"]
               |> Enum.flat_map(fn row ->
                 Enum.with_index(row["states"], fn state, index ->
                   {state, {row["item"], div(index, 2)}}
                 end)
               end)
               |> Map.new()
  unless byte_size(@replace) == @count and
           Enum.all?(:binary.bin_to_list(@replace), &(&1 in 0..3)) and
           map_size(@plain) == 184 and map_size(@slabs) == 101 and map_size(@pillars) == 60 and
           map_size(@slab_states) == 606 and
           Enum.all?(@slabs, fn {_item, states} -> tuple_size(states) == 6 end) and
           Enum.all?(@plain, fn {_item, state} ->
             is_integer(state) and state in 0..(@count - 1) and :binary.at(@replace, state) == 1
           end) and
           Enum.all?(@slab_states, fn {state, _} ->
             is_integer(state) and state in 0..(@count - 1) and :binary.at(@replace, state) == 3
           end) and
           Enum.all?(@pillars, fn {_item, states} ->
             tuple_size(states) == 3 and
               Enum.all?(Tuple.to_list(states), fn state ->
                 is_integer(state) and state in 0..(@count - 1) and
                   :binary.at(@replace, state) == 1
               end)
           end),
         do: raise("Invalid placement facts")

  # Class-keyed behaviours must choose the same placement as the item tables.
  unless Enum.all?(Map.keys(@slabs), &(Valimc.Block.item_behaviour(&1) == Valimc.Block.Slab)) and
           Enum.all?(
             Map.keys(@pillars),
             &(Valimc.Block.item_behaviour(&1) == Valimc.Block.Pillar)
           ) and
           Enum.all?(Map.keys(@plain), &(Valimc.Block.item_behaviour(&1) == Valimc.Block.Default)) and
           Valimc.Block.item_behaviour(@chest_item) == Valimc.Block.Chest and
           Enum.all?(@cooking_items, &(Valimc.Block.item_behaviour(&1) == Valimc.Block.Cooking)) and
           Enum.all?(Map.keys(@slab_states), &(Valimc.Block.behaviour(&1) == Valimc.Block.Slab)),
         do: raise("Block behaviours disagree with the placement facts")

  @doc "Propose a state from an immutable clicked/adjacent sample, without granting a world write."
  def candidate(
        item,
        clicked,
        adjacent,
        %{
          position: {x, y, z} = position,
          face: face,
          cursor: {_cx, cy, _cz}
        } = request
      )
      when is_integer(item) and is_integer(clicked) and clicked >= 0 and clicked < @count and
             is_integer(adjacent) and adjacent >= 0 and adjacent < @count and
             is_integer(face) and face in 0..5 and is_integer(x) and is_integer(y) and
             is_integer(z) and x in -33_554_432..33_554_431 and y in -2048..2047 and
             z in -33_554_432..33_554_431 and is_number(cy) do
    if supported_item?(item) do
      # Native hit coordinates are translated to double before relative height is tested.
      upper = y + cy - y > 0.5

      with {:ok, replace} <- replaceable(clicked, item, face, upper, true),
           target = if(replace, do: position, else: offset(position, face)),
           state = if(replace, do: clicked, else: adjacent),
           {:ok, true} <-
             if(replace, do: {:ok, true}, else: replaceable(state, item, face, upper, false)),
           {:ok, placed} <- candidate_state(item, state, face, upper, request) do
        {:ok, %{position: target, state: placed, replace_clicked: replace}}
      else
        {:ok, false} -> {:error, :occupied}
        error -> error
      end
    else
      {:error, :unsupported_item}
    end
  end

  def candidate(_, _, _, _), do: {:error, :invalid_context}

  def adjacent(%{position: position, face: face}) when face in 0..5,
    do: offset(position, face)

  def supported_item?(item),
    do:
      item in @facing_items or Map.has_key?(@plain, item) or Map.has_key?(@slabs, item) or
        Map.has_key?(@pillars, item)

  @doc "Container names need owned metadata and loot-copy support before item consumption."
  def supported_stack?(%Valimc.Protocol.ItemStack{item_id: item, components: components})
      when item in @facing_items,
      do: not Map.has_key?(components, "minecraft:custom_name")

  def supported_stack?(%Valimc.Protocol.ItemStack{item_id: item}), do: supported_item?(item)
  def supported_stack?(_), do: false

  @doc "Validate a saved edit independently of transient player yaw; destination permissions still fence its exact block state."
  def saved_candidate(item, clicked, adjacent, request, edits)
      when item in @facing_items and is_map(edits) and is_map(request) do
    case Map.to_list(edits) do
      [{position, state}] ->
        Enum.find_value([0.0, 90.0, 180.0, 270.0], {:error, :invalid_context}, fn yaw ->
          case candidate(item, clicked, adjacent, Map.put(request, :yaw, yaw)) do
            {:ok, %{position: ^position, state: ^state}} = result -> result
            _ -> nil
          end
        end)

      _ ->
        {:error, :invalid_context}
    end
  end

  def saved_candidate(item, clicked, adjacent, request, _edits),
    do: candidate(item, clicked, adjacent, request)

  defp candidate_state(item, state, face, upper, request),
    do: Valimc.Block.placement(item, state, face, upper, request)

  @doc "Placement facts read by the block behaviours."
  def plain_state(item), do: Map.fetch!(@plain, item)
  def slab_states(item), do: Map.fetch!(@slabs, item)
  def slab_half(state), do: Map.get(@slab_states, state)
  def pillar_states(item), do: Map.fetch!(@pillars, item)

  defp replaceable(state, item, face, upper, clicked) do
    case :binary.at(@replace, state) do
      0 ->
        {:error, :unsupported_replacement}

      1 ->
        {:ok, false}

      2 ->
        {:ok, true}

      3 ->
        {:ok, Valimc.Block.replaceable?(state, item, face, upper, clicked)}
    end
  end

  defp offset({x, y, z}, 0), do: {x, y - 1, z}
  defp offset({x, y, z}, 1), do: {x, y + 1, z}
  defp offset({x, y, z}, 2), do: {x, y, z - 1}
  defp offset({x, y, z}, 3), do: {x, y, z + 1}
  defp offset({x, y, z}, 4), do: {x - 1, y, z}
  defp offset({x, y, z}, 5), do: {x + 1, y, z}
end
