defmodule Valimc.World.ContainerSpills do
  @moduledoc "Bounded region-owned stored-stack release. Only the enclosing joint journal publishes the returned item proposal."
  alias Valimc.ItemMotionState
  alias Valimc.Physics.ContainerScatter
  alias Valimc.World.Items

  def add(items, key, removed) do
    Enum.reduce_while(removed, {:ok, items}, fn %{position: position, entry: entry},
                                                {:ok, current} ->
      case release(current, key, position, Tuple.to_list(entry.slots)) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

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

      case Items.create_record(current, key, record) do
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
