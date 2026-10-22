defmodule Valimc.World.ContainerSpills do
  @moduledoc "A broken container's stacks scatter as item entities, in the same commit as its block change."
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Entity.ContainerScatter
  alias Valimc.World.CookingEntry
  alias Valimc.Entity.Store

  def add(items, key, removed) do
    Enum.reduce_while(removed, {:ok, items}, fn %{position: position, entry: entry},
                                                {:ok, current} ->
      result =
        case entry do
          %{slots: slots} ->
            release(current, key, position, Tuple.to_list(slots))

          %{cooking: _} ->
            if CookingEntry.empty?(entry),
              do: {:ok, current},
              else: {:error, :occupied_cooking_entry}
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Admit one native furnace fuel remainder into the enclosing joint proposal."
  def add_remainder(items, _key, _position, []), do: {:ok, items}
  def add_remainder(items, key, position, [stack]), do: release(items, key, position, [stack])
  def add_remainder(_, _, _, _), do: {:error, :invalid_cooking_remainder}

  defp release(items, key, position, stacks) do
    Enum.reduce_while(stacks, {:ok, items}, fn
      nil, acc ->
        {:cont, acc}

      stack, {:ok, current} ->
        with {:ok, piles} <-
               ContainerScatter.plan(
                 position,
                 stack.count,
                 {uniform(), uniform(), uniform()},
                 draws(stack.count, [])
               ),
             {:ok, next} <- admit(current, key, stack, piles) do
          {:cont, {:ok, next}}
        else
          error -> {:halt, error}
        end
    end)
  end

  defp admit(items, key, stack, piles) do
    Enum.reduce_while(piles, {:ok, items}, fn pile, {:ok, current} ->
      {x, y, z} = pile.position

      record = %{
        uuid: :crypto.strong_rand_bytes(16),
        x: x,
        y: y,
        z: z,
        stack: %{stack | count: pile.count},
        motion: %ItemMotionState{velocity: pile.velocity, pickup_delay: pile.pickup_delay}
      }

      case Store.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp draws(0, acc), do: Enum.reverse(acc)

  defp draws(remaining, acc) do
    size = :rand.uniform(21) - 1
    velocities = {uniform(), uniform(), uniform(), uniform(), uniform(), uniform()}
    draws(max(0, remaining - size - 10), [{size, velocities} | acc])
  end

  defp uniform, do: (:rand.uniform(9_007_199_254_740_992) - 1) / 9_007_199_254_740_992
end
