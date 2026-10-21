defmodule Valimc.World.CookingBatch do
  @moduledoc "Bounded owned cooking proposals; only the enclosing durable commit publishes a result."
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.World.{Containers, ContainerSpills, CookingEntry, Items}
  @limit 1024

  @doc "Whether an owned processor can change on its next logical tick."
  def awake?(%{kind: kind, cooking: %Cooking{} = cooking}, block) do
    with true <- kind != nil and CookingBlocks.kind(block) == kind,
         {:ok, next, events} <- Cooking.step(cooking, block),
         {:ok, replacement} <- CookingBlocks.lit(block, events.lit) do
      next != cooking or replacement != block
    else
      _ -> false
    end
  end

  def awake?(_, _), do: false

  def plan(%Containers{} = containers, %Items{} = items, key, blocks)
      when is_map(blocks) and map_size(blocks) <= @limit do
    with {:ok, _} <- Containers.encode(key, containers),
         true <- Enum.all?(blocks, &consistent?(&1, containers)) do
      initial = %{
        containers: containers,
        items: items,
        expected: blocks,
        changes: %{},
        changed: [],
        refused: %{}
      }

      result =
        blocks
        |> Enum.sort()
        |> Enum.reduce(initial, fn {position, block}, acc ->
          entry = acc.containers.entries[position]

          case advance(acc, key, position, block, entry) do
            {:ok, next} -> next
            {:error, reason} -> %{acc | refused: Map.put(acc.refused, position, reason)}
          end
        end)

      with {:ok, _} <- Containers.encode(key, result.containers),
           do: {:ok, %{result | changed: Enum.reverse(result.changed)}}
    else
      false -> {:error, :invalid_cooking_batch}
      error -> error
    end
  end

  def plan(_, _, _, _), do: {:error, :invalid_cooking_batch}

  defp consistent?({position, block}, containers) do
    kind = CookingBlocks.kind(block)
    kind != nil and match?(%{kind: ^kind, cooking: %Cooking{}}, containers.entries[position])
  end

  defp advance(acc, key, position, block, entry) do
    with {:ok, cooking, events} <- Cooking.step(entry.cooking, block),
         {:ok, replacement} <- CookingBlocks.lit(block, events.lit),
         recipes = uses(entry.recipes, events.completed),
         {:ok, containers} <- replace(acc.containers, position, entry, cooking, recipes),
         {:ok, items} <- ContainerSpills.add_remainder(acc.items, key, position, events.drops) do
      changed = cooking != entry.cooking or recipes != entry.recipes or replacement != block
      content_changed = cooking.slots != entry.cooking.slots or recipes != entry.recipes

      {:ok,
       %{
         acc
         | containers: containers,
           items: items,
           changes:
             if(replacement != block or content_changed,
               do: Map.put(acc.changes, position, replacement),
               else: acc.changes
             ),
           changed: if(changed, do: [position | acc.changed], else: acc.changed)
       }}
    end
  end

  defp uses(recipes, nil), do: recipes
  defp uses(recipes, key), do: Map.update(recipes, key, 1, &(&1 + 1))

  defp replace(containers, position, entry, cooking, recipes) do
    next = %{entry | cooking: cooking, recipes: recipes}

    with {:ok, _} <- CookingEntry.encode(next) do
      if cooking.slots == entry.cooking.slots and recipes == entry.recipes do
        # Menu request revisions fence item identity/count and recipe awards.
        # The same region owns timers; progress cannot invalidate an item intent.
        {:ok, %{containers | entries: Map.put(containers.entries, position, next)}}
      else
        with {:ok, updated, _} <-
               Containers.replace_cooking(containers, position, entry.revision, cooking, recipes),
             do: {:ok, updated}
      end
    end
  end
end
