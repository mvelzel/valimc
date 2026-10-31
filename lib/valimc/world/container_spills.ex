defmodule Valimc.World.ContainerSpills do
  @moduledoc """
  A broken container's stacks scatter as item entities, in the same commit as
  its block change. A shulker box's stay inside it instead (VMC-032c2): the
  box drops as its item holding them, as its loot table copies its block
  entity's `container` (`ShulkerBoxBlock.getDrops`), or as a creative
  player's break drops a filled one (`playerWillDestroy`).
  """
  alias Valimc.Blocks.ShulkerBox
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Entity.ContainerScatter
  alias Valimc.World.CookingEntry
  alias Valimc.Entity.Store

  @doc """
  Add what the `removed` entries release to `items`. `drop` says how a shulker
  box goes: `:loot` (the default) pops the box with its contents as block
  loot does; `:creative` drops a box that holds anything at its centre and an
  empty one not at all.
  """
  def add(items, key, removed, drop \\ :loot) when drop in [:loot, :creative] do
    Enum.reduce_while(removed, {:ok, items}, fn %{position: position, entry: entry} = gone,
                                                {:ok, current} ->
      result =
        case entry do
          %{kind: :shulker_box, slots: slots} ->
            shulker_box(current, key, position, gone.block, slots, drop)

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

  @doc """
  The block loot a player's break pops, without the shulker box items the
  `removed` entries drop themselves: one record of each box's item, which the
  box's loot table yields once.
  """
  def without_boxes(records, removed) do
    Enum.reduce(removed, records, fn
      %{entry: %{kind: :shulker_box}, block: block}, acc ->
        item = ShulkerBox.item(block)

        case Enum.find_index(acc, &match?(%{stack: %{item_id: ^item}}, &1)) do
          nil -> acc
          index -> List.delete_at(acc, index)
        end

      _, acc ->
        acc
    end)
  end

  # A creative break drops a filled box at its centre, moving as
  # `new ItemEntity(level, x, y, z, stack)` sets out, with the default pickup
  # delay; an empty one drops nothing.
  defp shulker_box(items, key, {x, y, z}, block, slots, :creative) do
    if ShulkerBox.component(slots) == nil do
      {:ok, items}
    else
      record = %{
        uuid: :crypto.strong_rand_bytes(16),
        x: x + 0.5,
        y: y + 0.5,
        z: z + 0.5,
        stack: ShulkerBox.drop(block, slots),
        motion: %ItemMotionState{
          velocity: {uniform() * 0.2 - 0.1, 0.2, uniform() * 0.2 - 0.1},
          pickup_delay: 10
        }
      }

      with {:ok, next, _} <- Store.create_record(items, key, record), do: {:ok, next}
    end
  end

  defp shulker_box(items, key, position, block, slots, :loot) do
    record = Valimc.Entity.ItemDrop.pop(position, ShulkerBox.drop(block, slots))

    with {:ok, next, _} <- Store.create_record(items, key, record),
         do: {:ok, next}
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
