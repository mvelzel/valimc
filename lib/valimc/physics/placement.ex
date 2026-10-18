defmodule Valimc.Physics.Placement do
  @moduledoc "Pure native placement candidates; owners still admit geometry, writes and consumption."
  alias Valimc.Physics.{ChestPlacement, FluidBlocks}
  @chest_item Valimc.Protocol.Data.item("chest")
  @path Path.expand("../../../priv/physics/placement.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count 35_723
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
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
      item == @chest_item or Map.has_key?(@plain, item) or Map.has_key?(@slabs, item) or
        Map.has_key?(@pillars, item)

  @doc "Chest names require owned metadata and loot-copy support before item consumption."
  def supported_stack?(%Valimc.Protocol.ItemStack{item_id: @chest_item, components: components}),
    do: not Map.has_key?(components, "minecraft:custom_name")

  def supported_stack?(%Valimc.Protocol.ItemStack{item_id: item}), do: supported_item?(item)
  def supported_stack?(_), do: false

  @doc "Validate a saved edit independently of transient player yaw; destination permissions still fence its exact block state."
  def saved_candidate(@chest_item, clicked, adjacent, request, edits)
      when is_map(edits) and is_map(request) do
    case Map.to_list(edits) do
      [{position, state}] ->
        Enum.find_value([0.0, 90.0, 180.0, 270.0], {:error, :invalid_context}, fn yaw ->
          case candidate(@chest_item, clicked, adjacent, Map.put(request, :yaw, yaw)) do
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

  defp candidate_state(@chest_item, state, _, _, request),
    do: ChestPlacement.single_state(request[:yaw], state)

  defp candidate_state(item, state, face, upper, _), do: {:ok, placed(item, state, face, upper)}

  defp replaceable(state, item, face, upper, clicked) do
    case :binary.at(@replace, state) do
      0 ->
        {:error, :unsupported_replacement}

      1 ->
        {:ok, false}

      2 ->
        {:ok, true}

      3 ->
        {slab_item, half} = Map.fetch!(@slab_states, state)

        {:ok,
         slab_item == item and half != 2 and
           (not clicked or (half == 1 and (face == 1 or (face >= 2 and upper))) or
              (half == 0 and (face == 0 or (face >= 2 and not upper))))}
    end
  end

  defp placed(item, previous, face, upper) do
    case Map.fetch(@slabs, item) do
      {:ok, states} ->
        case Map.get(@slab_states, previous) do
          {^item, _} ->
            elem(states, 5)

          _ ->
            {:ok, fluid} = FluidBlocks.fetch(previous)
            top = face == 0 or (face >= 2 and upper)

            index =
              if(top, do: 0, else: 2) + if(fluid.kind == :water and fluid.source, do: 0, else: 1)

            elem(states, index)
        end

      :error ->
        case Map.fetch(@pillars, item) do
          {:ok, states} ->
            axis =
              cond do
                face < 2 -> 1
                face < 4 -> 2
                true -> 0
              end

            elem(states, axis)

          :error ->
            Map.fetch!(@plain, item)
        end
    end
  end

  defp offset({x, y, z}, 0), do: {x, y - 1, z}
  defp offset({x, y, z}, 1), do: {x, y + 1, z}
  defp offset({x, y, z}, 2), do: {x, y, z - 1}
  defp offset({x, y, z}, 3), do: {x, y, z + 1}
  defp offset({x, y, z}, 4), do: {x - 1, y, z}
  defp offset({x, y, z}, 5), do: {x + 1, y, z}
end
