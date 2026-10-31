defmodule Valimc.World.CookingEntry do
  @moduledoc "Bounded persistent cooking inventory/progress within the existing region container authority."
  alias Valimc.Blocks.Cooking
  alias Valimc.Protocol.ItemStack
  @kinds [:furnace, :smoker, :blast_furnace]
  @recipes List.to_tuple(Valimc.Blocks.CookingRecipes.names())
  @recipe_ids Valimc.Blocks.CookingRecipes.ids()
  @max_bytes 524_288

  def new(kind) when kind in @kinds, do: {:ok, %{kind: kind, cooking: %Cooking{}, recipes: %{}}}
  def new(_), do: invalid()

  def empty?(%{
        cooking: %Cooking{slots: {nil, nil, nil}, burn_left: 0, progress: 0},
        recipes: recipes
      })
      when is_map(recipes) and map_size(recipes) == 0, do: true

  def empty?(_), do: false

  # A name (VMC-032c5) is the container snapshot's, not the cooking bytes'.
  def encode(%{name: _} = entry), do: encode(Map.delete(entry, :name))

  def encode(%{kind: kind, revision: revision, cooking: cooking, recipes: recipes} = entry)
      when map_size(entry) == 4 and kind in @kinds and is_integer(revision) and
             revision in 1..18_446_744_073_709_551_615 and is_map(recipes) and
             map_size(recipes) <= 107 do
    true = Cooking.valid?(cooking)

    slots =
      Enum.map(Tuple.to_list(cooking.slots), fn stack ->
        bytes = stack |> ItemStack.encode() |> IO.iodata_to_binary()
        {:ok, ^stack} = ItemStack.decode(bytes)
        bytes
      end)
      |> IO.iodata_to_binary()

    uses =
      recipes
      |> Enum.map(fn {key, count} ->
        id = Map.fetch!(@recipe_ids, key)
        true = is_integer(count) and count in 1..2_147_483_647
        {id, count}
      end)
      |> Enum.sort()
      |> Enum.map(fn {id, count} -> <<id::16, count::32>> end)

    kind_id = Enum.find_index(@kinds, &(&1 == kind))
    speed = trunc(cooking.speed)

    bytes =
      IO.iodata_to_binary([
        <<kind_id, cooking.burn_left::32, cooking.burn_total::32, cooking.progress::32,
          cooking.total::32, speed, byte_size(slots)::32, map_size(recipes)>>,
        slots,
        uses
      ])

    true = byte_size(bytes) <= @max_bytes
    {:ok, bytes}
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def encode(_), do: invalid()

  def decode(bytes, revision) when is_binary(bytes) and byte_size(bytes) in 26..@max_bytes do
    <<kind, burn_left::32, burn_total::32, progress::32, total::32, speed, size::32, count,
      body::binary>> = bytes

    true = kind in 0..2 and speed in 1..2 and size in 3..@max_bytes and count <= 107
    <<slot_bytes::binary-size(^size), uses::binary>> = body
    true = byte_size(uses) == count * 6
    {slots, <<>>} = take_slots(slot_bytes, 3, [])

    recipes =
      Enum.reduce(for(<<id::16, used::32 <- uses>>, do: {id, used}), %{}, fn {id, used}, acc ->
        key = elem(@recipes, id)
        false = Map.has_key?(acc, key)
        Map.put(acc, key, used)
      end)

    cooking = %Cooking{
      slots: slots |> Enum.reverse() |> List.to_tuple(),
      burn_left: burn_left,
      burn_total: burn_total,
      progress: progress,
      total: total,
      speed: speed * 1.0
    }

    entry = %{kind: Enum.at(@kinds, kind), revision: revision, cooking: cooking, recipes: recipes}
    {:ok, ^bytes} = encode(entry)
    {:ok, entry}
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def decode(_, _), do: invalid()
  defp take_slots(bytes, 0, slots), do: {slots, bytes}

  defp take_slots(bytes, remaining, slots) do
    {:ok, stack, rest} = ItemStack.take(bytes)
    take_slots(rest, remaining - 1, [stack | slots])
  end

  defp invalid, do: {:error, :invalid_cooking_entry}
end
