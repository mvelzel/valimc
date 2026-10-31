defmodule Valimc.World.ContainerSpills do
  @moduledoc """
  A broken container's stacks scatter as item entities, in the same commit as
  its block change. A shulker box's stay inside it instead (VMC-032c2): the
  box drops as its item holding them, as its loot table copies its block
  entity's `container` (`ShulkerBoxBlock.getDrops`), or as a creative
  player's break drops a filled one (`playerWillDestroy`).

  A furnace, smoker or blast furnace (VMC-032c5) spills its three slots as a
  chest does and pays out its stored recipes' experience as orbs at the
  block's centre (`AbstractFurnaceBlockEntity.preRemoveSideEffects`), in
  survival and creative alike. A named container's block loot carries its
  name (`copy_components` of `minecraft:custom_name`).
  """
  alias Valimc.Blocks.{CookingAwards, ShulkerBox}
  alias Valimc.Entity.{ContainerScatter, ExperienceOrbs, ItemMotionState, Store}
  alias Valimc.Protocol.ItemStack

  @custom_name "minecraft:custom_name"

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
            shulker_box(current, key, position, gone.block, slots, entry[:name], drop)

          %{slots: slots} ->
            release(current, key, position, Tuple.to_list(slots))

          %{cooking: cooking, recipes: recipes} ->
            with {:ok, next} <- release(current, key, position, Tuple.to_list(cooking.slots)),
                 do: experience(next, key, position, recipes)
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  # Each stored recipe's `amount * experience`, the fraction by chance, as
  # orbs at the block's centre (`getRecipesToAwardAndPopExperience`).
  defp experience(items, _key, _position, recipes) when map_size(recipes) == 0,
    do: {:ok, items}

  defp experience(items, key, position, recipes) do
    draws =
      Map.new(recipes, fn {name, _} ->
        <<sample::24>> = :crypto.strong_rand_bytes(3)
        {name, sample}
      end)

    with {:ok, orbs} <- cooking_orbs(position, recipes, draws) do
      Enum.reduce_while(orbs, {:ok, items}, fn orb, {:ok, current} ->
        case Store.create_record(current, key, orb) do
          {:ok, next, _} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  The orb records a removed furnace at `position` pays out for its stored
  `recipes` (uses by recipe), with each recipe's fraction drawn from `draws`
  (unsigned 24-bit `nextFloat` samples, `CookingAwards.plan/2`): at the
  block's centre (`Vec3.atCenterOf`), each recipe awarded on its own.
  """
  def cooking_orbs({x, y, z}, recipes, draws) do
    with {:ok, award} <- CookingAwards.plan(recipes, draws),
         do: {:ok, ExperienceOrbs.award({x + 0.5, y + 0.5, z + 0.5}, award)}
  end

  @doc """
  The block loot a player's break pops, as the `removed` entries' block
  entities make it: without the shulker box items those entries drop
  themselves (one record of each box's item, which the box's loot table
  yields once), and with a named container's name on its own item.
  """
  def loot(records, removed) do
    Enum.reduce(removed, records, fn
      %{entry: %{kind: :shulker_box}, block: block}, acc ->
        item = ShulkerBox.item(block)

        case Enum.find_index(acc, &match?(%{stack: %{item_id: ^item}}, &1)) do
          nil -> acc
          index -> List.delete_at(acc, index)
        end

      %{entry: %{name: name}, block: block}, acc ->
        item = block_item(block)

        case names?(block) && Enum.find_index(acc, &unnamed?(&1.stack, item)) do
          index when is_integer(index) ->
            List.update_at(acc, index, &%{&1 | stack: named(&1.stack, name)})

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  @doc """
  A block's drops with its block entity's `name` copied onto its own item,
  where its loot table copies the name (`copy_components` of
  `minecraft:custom_name`, on the entry of the block's own item in every
  such table).
  """
  def name_drops(stacks, _block, nil), do: stacks

  def name_drops(stacks, block, name) do
    item = block_item(block)

    case names?(block) && Enum.find_index(stacks, &unnamed?(&1, item)) do
      index when is_integer(index) -> List.update_at(stacks, index, &named(&1, name))
      _ -> stacks
    end
  end

  # Whether the block's loot table copies its name.
  defp names?(block) do
    case Valimc.Blocks.MiningLoot.table(block) do
      nil -> false
      table -> Valimc.Blocks.Loot.names?(table)
    end
  end

  # A container block's own item (`Block.asItem`), named as its block.
  defp block_item(block),
    do: Valimc.Protocol.Data.item(Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(block)))

  defp unnamed?(%ItemStack{item_id: item, components: components}, item),
    do: not Map.has_key?(components, @custom_name)

  defp unnamed?(_, _), do: false

  defp named(stack, name),
    do: ItemStack.normalize(%{stack | components: Map.put(stack.components, @custom_name, name)})

  # A creative break drops a filled box at its centre, moving as
  # `new ItemEntity(level, x, y, z, stack)` sets out, with the default pickup
  # delay; an empty one drops nothing.
  defp shulker_box(items, key, {x, y, z}, block, slots, name, :creative) do
    if ShulkerBox.component(slots) == nil do
      {:ok, items}
    else
      record = %{
        uuid: :crypto.strong_rand_bytes(16),
        x: x + 0.5,
        y: y + 0.5,
        z: z + 0.5,
        stack: ShulkerBox.drop(block, slots, name),
        motion: %ItemMotionState{
          velocity: {uniform() * 0.2 - 0.1, 0.2, uniform() * 0.2 - 0.1},
          pickup_delay: 10
        }
      }

      with {:ok, next, _} <- Store.create_record(items, key, record), do: {:ok, next}
    end
  end

  defp shulker_box(items, key, position, block, slots, name, :loot) do
    record = Valimc.Entity.ItemDrop.pop(position, ShulkerBox.drop(block, slots, name))

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
