defmodule Valimc.Entity.ItemSpill do
  @moduledoc """
  What a destroyed item entity releases (VMC-004b8). `ItemEntity.hurtServer`
  calls `Item.onDestroyed` when fire, lava, a cactus or an explosion takes
  the last of its health: a block item (a shulker box) spills its container's
  filled slots in order and a bundle its contents, each as a new item where
  the destroyed one was, moving as `new ItemEntity(level, x, y, z, stack)`
  sets out (`ItemUtils.onContainerDestroyed`). An item that falls out of the
  world is discarded and spills nothing. Pure: the owner adds the records in
  the same store change that removes the destroyed item.
  """
  alias Valimc.Entity.{ItemMotionState, Store}
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @doc "The stacks `stack` releases when its entity is destroyed, in order."
  def contents(%ItemStack{} = stack) do
    container =
      if Valimc.Protocol.Data.item_block(stack.item_id) != nil,
        do: ItemStack.component(stack, "minecraft:container") || [],
        else: []

    bundle =
      if MapSet.member?(ItemTypes.defaults(stack.item_id).present, "minecraft:bundle_contents"),
        do: ItemStack.component(stack, "minecraft:bundle_contents") || [],
        else: []

    Enum.reject(container ++ bundle, &is_nil/1)
  end

  def contents(_), do: []

  @doc """
  Add the items `stack` releases at `position` to `store`; `{:ok, store}`, or
  the store's error, which leaves the caller's change unapplied.
  """
  def spill(store, key, %ItemStack{} = stack, {x, y, z}) do
    Enum.reduce_while(contents(stack), {:ok, store}, fn held, {:ok, current} ->
      record = %{
        uuid: :crypto.strong_rand_bytes(16),
        x: x,
        y: y,
        z: z,
        stack: held,
        motion: %ItemMotionState{velocity: {uniform() * 0.2 - 0.1, 0.2, uniform() * 0.2 - 0.1}}
      }

      case Store.create_record(current, key, record) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp uniform, do: (:rand.uniform(9_007_199_254_740_992) - 1) / 9_007_199_254_740_992
end
