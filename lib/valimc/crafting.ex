defmodule Valimc.Crafting do
  @moduledoc "Indexed ordinary 2×2/3×3 recipes; results are derived, never owned inventory."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @path Path.expand("../../priv/crafting/recipes.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @remainder_path Path.expand("../../priv/crafting/remainders.json", __DIR__)
  @external_resource @remainder_path
  @remainder_facts JSON.decode!(File.read!(@remainder_path))
  unless Valimc.Version.stamped?(@facts),
    do: raise("Wrong player crafting catalog version")

  unless Map.take(@remainder_facts, ["version", "data_version", "server_sha1"]) ==
           Map.take(@facts, ["version", "data_version", "server_sha1"]) and
           length(@remainder_facts["recipes"]) == 3 and
           @remainder_facts["remainders"] == %{"1134" => 1128, "1533" => 1270},
         do: raise("Wrong crafting remainder catalog")

  @remainders Map.new(@remainder_facts["remainders"], fn {id, output} ->
                {String.to_integer(id), %ItemStack{item_id: output}}
              end)

  @recipes Enum.map(@facts["recipes"] ++ @remainder_facts["recipes"], fn row ->
             %{
               "name" => name,
               "width" => w,
               "height" => h,
               "ingredients" => ingredients,
               "result" => item,
               "count" => count
             } = row

             unless is_binary(name) and String.starts_with?(name, "minecraft:") and
                      is_list(ingredients) and length(ingredients) in 1..9 and
                      ((w == 0 and h == 0) or
                         (w in 1..3 and h in 1..3 and length(ingredients) == w * h)),
                    do: raise("Invalid player crafting recipe")

             sets =
               Enum.map(ingredients, fn
                 nil ->
                   nil

                 ids when is_list(ids) and ids != [] ->
                   unless Enum.all?(
                            ids,
                            &(is_integer(&1) and &1 > 0 and ItemTypes.item(&1) != nil)
                          ),
                          do: raise("Invalid crafting ingredient")

                   MapSet.new(ids)
               end)

             needed = Enum.reject(sets, &is_nil/1)
             result = %ItemStack{item_id: item, count: count}

             unless needed != [] and (w != 0 or length(needed) == length(sets)) and
                      ItemTypes.item(item) != nil and is_integer(count) and
                      count in 1..ItemStack.max_stack_size(result),
                    do: raise("Invalid crafting result")

             rules =
               for size <- [2, 3],
                   (w == 0 and length(needed) <= size * size) or
                     (w > 0 and w <= size and h <= size),
                   into: %{} do
                 rule =
                   if w == 0 do
                     {:bag, Enum.sort_by(needed, &MapSet.size/1)}
                   else
                     patterns =
                       for y <- 0..(size - h), x <- 0..(size - w), mirror <- [false, true] do
                         for gy <- 0..(size - 1), gx <- 0..(size - 1) do
                           if gx >= x and gx < x + w and gy >= y and gy < y + h do
                             sx = if mirror, do: w - 1 - gx + x, else: gx - x
                             Enum.at(sets, (gy - y) * w + sx)
                           end
                         end
                         |> List.to_tuple()
                       end

                     {:shape, Enum.uniq(patterns)}
                   end

                 {size, rule}
               end

             {name, rules, result, needed}
           end)
           |> List.to_tuple()
  unless tuple_size(@recipes) == 1183 and
           MapSet.size(MapSet.new(Enum.map(Tuple.to_list(@recipes), &elem(&1, 0)))) == 1183,
         do: raise("Incomplete or duplicate player crafting recipes")

  @index @recipes
         |> Tuple.to_list()
         |> Enum.with_index()
         |> Enum.reduce(%{}, fn
           {{_name, rules, _result, sets}, index}, by_input ->
             ids = Enum.reduce(sets, MapSet.new(), &MapSet.union/2)

             Enum.reduce(Map.keys(rules), by_input, fn size, by_size ->
               Enum.reduce(ids, by_size, fn id, acc ->
                 Map.update(acc, {size, length(sets), id}, [index], &[index | &1])
               end)
             end)
         end)
         |> Map.new(fn {key, indexes} -> {key, Enum.reverse(indexes)} end)

  @doc "Four or nine physical grid stacks, row-major; ordinary ingredients ignore patches/counts."
  def result(grid) when is_list(grid) and length(grid) in [4, 9] do
    with {:ok, ids} <- item_ids(grid) do
      size = if length(grid) == 4, do: 2, else: 3
      present = Enum.reject(ids, &(&1 == 0))

      result =
        Enum.find_value(
          Map.get(@index, {size, length(present), List.first(present)}, []),
          fn index ->
            {_name, rules, result, _sets} = elem(@recipes, index)
            if matches?(Map.fetch!(rules, size), ids, present), do: result
          end
        )

      if result, do: {:ok, result}, else: :none
    end
  end

  def result(_), do: {:error, :invalid_crafting_grid}

  def remainder(%ItemStack{item_id: id}), do: Map.get(@remainders, id)

  defp item_ids(grid) do
    Enum.reduce_while(grid, {:ok, []}, fn
      nil, {:ok, ids} ->
        {:cont, {:ok, [0 | ids]}}

      %ItemStack{item_id: id, count: count}, {:ok, ids}
      when is_integer(id) and id > 0 and is_integer(count) and count > 0 ->
        if ItemTypes.item(id),
          do: {:cont, {:ok, [id | ids]}},
          else: {:halt, {:error, :invalid_crafting_grid}}

      _, _ ->
        {:halt, {:error, :invalid_crafting_grid}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp matches?({:bag, sets}, _ids, present), do: bag?(sets, present)

  defp matches?({:shape, patterns}, ids, _present) do
    Enum.any?(patterns, fn cells ->
      ids
      |> Enum.with_index()
      |> Enum.all?(fn {id, i} ->
        case elem(cells, i) do
          nil -> id == 0
          set -> MapSet.member?(set, id)
        end
      end)
    end)
  end

  defp bag?([set], [id]), do: MapSet.member?(set, id)

  defp bag?([first, second], [a, b]),
    do:
      (MapSet.member?(first, a) and MapSet.member?(second, b)) or
        (MapSet.member?(first, b) and MapSet.member?(second, a))

  defp bag?(sets, input) do
    indexed = Enum.with_index(input)

    edges =
      Enum.reduce_while(sets, [], fn set, edges ->
        case for({id, i} <- indexed, MapSet.member?(set, id), do: i) do
          [] -> {:halt, false}
          cells -> {:cont, [cells | edges]}
        end
      end)

    if edges == false do
      false
    else
      edges = edges |> Enum.sort_by(&length/1) |> List.to_tuple()

      Enum.reduce_while(0..(tuple_size(edges) - 1), %{}, fn ingredient, matching ->
        case augment(ingredient, edges, matching, 0) do
          {:ok, next, _} -> {:cont, next}
          {:error, _} -> {:halt, false}
        end
      end) != false
    end
  end

  defp augment(ingredient, edges, matching, seen) do
    Enum.reduce_while(elem(edges, ingredient), {:error, seen}, fn cell, {:error, seen} ->
      flag = Bitwise.bsl(1, cell)

      if Bitwise.band(seen, flag) != 0 do
        {:cont, {:error, seen}}
      else
        seen = Bitwise.bor(seen, flag)

        case Map.fetch(matching, cell) do
          :error ->
            {:halt, {:ok, Map.put(matching, cell, ingredient), seen}}

          {:ok, previous} ->
            case augment(previous, edges, matching, seen) do
              {:ok, next, seen} -> {:halt, {:ok, Map.put(next, cell, ingredient), seen}}
              {:error, seen} -> {:cont, {:error, seen}}
            end
        end
      end
    end)
  end
end
