defmodule Valimc.Crafting2x2 do
  @moduledoc "Indexed ordinary player-grid recipes; results are derived, never owned inventory."
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  @path Path.expand("../../priv/crafting/player_recipes.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
         do: raise("Wrong player crafting catalog version")

  @recipes Enum.map(@facts["recipes"], fn row ->
             %{
               "name" => name,
               "width" => w,
               "height" => h,
               "ingredients" => ingredients,
               "result" => item,
               "count" => count
             } = row

             unless is_binary(name) and String.starts_with?(name, "minecraft:") and
                      is_list(ingredients) and length(ingredients) in 1..4 and
                      ((w == 0 and h == 0) or
                         (w in 1..2 and h in 1..2 and length(ingredients) == w * h)),
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

             rule =
               if w == 0 do
                 {:bag, Enum.sort_by(needed, &MapSet.size/1)}
               else
                 patterns =
                   for y <- 0..(2 - h), x <- 0..(2 - w), mirror <- [false, true] do
                     for gy <- 0..1, gx <- 0..1 do
                       if gx >= x and gx < x + w and gy >= y and gy < y + h do
                         sx = if mirror, do: w - 1 - gx + x, else: gx - x
                         Enum.at(sets, (gy - y) * w + sx)
                       end
                     end
                     |> List.to_tuple()
                   end

                 {:shape, Enum.uniq(patterns)}
               end

             {name, rule, result, needed}
           end)
           |> List.to_tuple()
  unless tuple_size(@recipes) == 476 and
           MapSet.size(MapSet.new(Enum.map(Tuple.to_list(@recipes), &elem(&1, 0)))) == 476,
         do: raise("Incomplete or duplicate player crafting recipes")

  @index @recipes
         |> Tuple.to_list()
         |> Enum.with_index()
         |> Enum.reduce(%{}, fn
           {{_name, _rule, _result, sets}, index}, by_input ->
             ids = Enum.reduce(sets, MapSet.new(), &MapSet.union/2)

             Enum.reduce(ids, by_input, fn id, acc ->
               Map.update(acc, {length(sets), id}, [index], &[index | &1])
             end)
         end)
         |> Map.new(fn {key, indexes} -> {key, Enum.reverse(indexes)} end)

  @doc "Four physical grid stacks, row-major; item patches/counts do not change ordinary ingredients."
  def result(grid) when is_list(grid) and length(grid) == 4 do
    with {:ok, ids} <- item_ids(grid) do
      present = Enum.reject(ids, &(&1 == 0))

      result =
        Enum.find_value(Map.get(@index, {length(present), List.first(present)}, []), fn index ->
          {_name, rule, result, _sets} = elem(@recipes, index)
          if matches?(rule, ids, present), do: result
        end)

      if result, do: {:ok, result}, else: :none
    end
  end

  def result(_), do: {:error, :invalid_crafting_grid}

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

  defp bag?([], []), do: true

  defp bag?([set | rest], input) do
    input
    |> Enum.with_index()
    |> Enum.any?(fn {id, i} ->
      MapSet.member?(set, id) and bag?(rest, List.delete_at(input, i))
    end)
  end
end
