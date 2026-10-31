defmodule Valimc.Blocks.ShulkerBox do
  @moduledoc """
  Shulker boxes (`ShulkerBoxBlock`, VMC-032c2), the plain one and the sixteen
  dyed ones: a 27-slot storage entry (`Valimc.World.Containers.create_storage/4`)
  behind the shulker box menu, whose slots take nothing that cannot fit
  inside a container item (`ShulkerBoxSlot`), as hoppers and droppers do not
  (`canPlaceItemThroughFace`).

  The contents travel with the box: a box placed from an item that carries a
  `minecraft:container` takes its slots (`BaseContainerBlockEntity.
  applyImplicitComponents`), and a broken box drops as its item with them
  (`collectImplicitComponents`, which the block loot's `copy_components`
  reads). Its lid opens and closes by block event 1 with the opener count,
  as a chest's, and only when there is room for it (`canOpen`).
  """
  use Valimc.Blocks.Behaviour
  alias Valimc.Data.Blocks
  alias Valimc.Physics.{CollisionContext, Kernel}
  alias Valimc.Protocol.{Data, ItemStack}

  @names for id <- 0..(Blocks.block_count() - 1),
             name = Blocks.name(id),
             Blocks.class(Blocks.default_state(name)) == "ShulkerBoxBlock",
             do: name
  unless length(@names) == 17, do: raise("Expected the 17 shulker boxes")

  @ranges Enum.map(@names, &Blocks.states/1)
  @states Enum.flat_map(@ranges, &Enum.to_list/1)
  @set MapSet.new(@states)
  @items MapSet.new(@names, &Data.item/1)
  @size 27
  @directions %{
    "down" => {0, -1, 0},
    "up" => {0, 1, 0},
    "north" => {0, 0, -1},
    "south" => {0, 0, 1},
    "west" => {-1, 0, 0},
    "east" => {1, 0, 0}
  }
  @container "minecraft:container"

  @impl true
  def block_entity(state) do
    if shulker_box?(state), do: :shulker_box
  end

  @doc "Every shulker box state."
  def states, do: @states

  @doc "Whether a block state is a shulker box."
  def shulker_box?(state), do: is_integer(state) and MapSet.member?(@set, state)

  @doc """
  Whether a stack is a shulker box, which cannot go inside a container item
  (`BlockItem.canFitInsideContainerItems`).
  """
  def item?(%ItemStack{item_id: item}), do: MapSet.member?(@items, item)
  def item?(_), do: false

  @doc "The unit step of the face a box opens out of (`FACING`)."
  def facing(state), do: Map.fetch!(@directions, property(state, "facing"))

  @doc "The block-event packet that sets a box's lid moving (`triggerEvent(1, count)`)."
  def lid_event(state, position, open?) when is_boolean(open?),
    do:
      Valimc.Protocol.Packets.block_event(
        position,
        1,
        if(open?, do: 1, else: 0),
        Blocks.block_id(state)
      )

  @doc """
  `ShulkerBoxBlock.canOpen` for a closed box: the half block in front of its
  lid (`Shulker.getProgressDeltaAabb(1, facing, 0, 0.5)` deflated by 1e-6)
  meets no block's collision shape. `neighbour` is the state of the cell the
  box faces (nil outside the world, which is clear). Entities that collide
  like blocks (boats, shulkers) are not consulted.
  """
  def lid_clear?(state, {x, y, z}, neighbour) do
    {dx, dy, dz} = facing(state)

    if neighbour == nil do
      true
    else
      e = 1.0e-6
      {x0, x1} = span(x, dx)
      {y0, y1} = span(y, dy)
      {z0, z1} = span(z, dz)
      box = {x0 + e, y0 + e, z0 + e, x1 - e, y1 - e, z1 - e}

      not Kernel.obstructs?(
        neighbour,
        {x + dx, y + dy, z + dz},
        CollisionContext.empty(),
        [box]
      )
    end
  end

  # The box's extent on one axis moved half a block along its facing.
  defp span(c, 1), do: {c + 1.0, c + 1.5}
  defp span(c, -1), do: {c - 0.5, c * 1.0}
  defp span(c, 0), do: {c * 1.0, c + 1.0}

  @doc "The cell a box opens toward."
  def front(state, {x, y, z}) do
    {dx, dy, dz} = facing(state)
    {x + dx, y + dy, z + dz}
  end

  @doc """
  A box's slots as its item's `minecraft:container` component
  (`ItemContainerContents.fromItems`): up to the last filled slot, or nil
  when all are empty (the item's default).
  """
  def component(slots) when is_tuple(slots) do
    case slots |> Tuple.to_list() |> Enum.reverse() |> Enum.drop_while(&is_nil/1) do
      [] -> nil
      kept -> Enum.reverse(kept)
    end
  end

  @doc """
  The slots a box placed from `stack` holds (`ItemContainerContents.copyInto`):
  `{:ok, slots}`, or `:error` when the component fills a slot beyond the
  box's 27, which ValiMC refuses rather than drop as vanilla does.
  """
  def slots(%ItemStack{} = stack) do
    case ItemStack.component(stack, @container) do
      list when is_list(list) ->
        {head, tail} = Enum.split(list, @size)

        if Enum.all?(tail, &is_nil/1),
          do: {:ok, List.to_tuple(head ++ List.duplicate(nil, @size - length(head)))},
          else: :error

      _ ->
        {:ok, Tuple.duplicate(nil, @size)}
    end
  end

  @doc """
  Whether a stack of a box places: nothing on it but its contents. A name,
  lock or loot table (`custom_name`, `lock`, `container_loot`) needs more
  than the storage entry holds, so such a box does not place yet.
  """
  def placeable_stack?(%ItemStack{components: components, removed: removed} = stack) do
    item?(stack) and MapSet.size(removed) == 0 and
      Map.keys(components) -- [@container] == [] and match?({:ok, _}, slots(stack))
  end

  @doc """
  The item a broken box drops (its block's loot, with the block entity's
  components copied): the box of `state`'s colour holding `slots`.
  """
  def drop(state, slots) do
    stack = ItemStack.new(Blocks.name(Blocks.block_id(state)))

    case component(slots) do
      nil -> stack
      contents -> ItemStack.normalize(%{stack | components: %{@container => contents}})
    end
  end

  @doc "The item of a box state's colour."
  def item(state), do: Data.item(Blocks.name(Blocks.block_id(state)))

  defp property(state, name), do: state |> Blocks.properties() |> List.keyfind(name, 0) |> elem(1)
end
