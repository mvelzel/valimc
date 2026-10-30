defmodule Valimc.Player.Buckets do
  @moduledoc """
  Buckets (VMC-031a, VMC-043e8), as vanilla's `BucketItem.use`: the server casts the
  player's own ray (`getPlayerPOVHitResult`, `Valimc.Physics.Clip`) over the
  blocks within reach, through sources for an empty bucket; an empty bucket
  picks up what it hits (`BucketPickup`), a full one pours into the hit
  block if it takes water (a container), else beside the face, else once more
  beside it. The world changes in the hit cell's owner, the player's group,
  through the block rules (`Valimc.World.Region.bucket/2`); the held stack
  becomes the filled or empty bucket as `ItemUtils.createFilledResult` makes
  it. A mob bucket admits its saved animal after a successful pour in that
  same hosted callback; capture is the entity interaction path.

  Not here: the pickup and pour sounds for other players, the evaporation's
  smoke, statistics and advancements. An empty bucket from a stack whose
  filled bucket would have no room is refused rather than dropped.
  """
  alias Valimc.Blocks.Fluids
  alias Valimc.Data.{BlockFacts, Grid}
  alias Valimc.Entity.Bucketable
  alias Valimc.Living.Interaction
  alias Valimc.Menus.Inventory
  alias Valimc.Physics.Clip
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.World
  alias Valimc.World.Region

  @steps {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}

  @doc "Whether this item uses the bucket ray: empty, water, lava or an aquatic mob."
  def bucket?(%ItemStack{item_id: id}), do: content(id) != nil
  def bucket?(_), do: false

  defp content(id) do
    cond do
      id == ItemTypes.id("bucket") -> :empty
      id == ItemTypes.id("water_bucket") -> 2
      id == ItemTypes.id("lava_bucket") -> 4
      Bucketable.type(id) != nil -> 2
      true -> nil
    end
  end

  @doc "Use the bucket held in `hand` (`BucketItem.use`); the inventory is resynced."
  def use(state, hand) do
    stack = Inventory.held(state.inventory, hand)
    player = state.player
    mode = player.game_mode.current

    with true <- mode in [:survival, :creative],
         %{miss: false} = hit <- aim(player, content(stack.item_id)),
         {:ok, inventory} <- act(state, hand, stack, hit) do
      inventory = inventory |> Inventory.cancel_drag() |> Inventory.advance()
      Valimc.Player.CreativeInventory.resync_inventory(%{state | inventory: inventory})
    else
      _ -> Valimc.Player.CreativeInventory.resync_inventory(state)
    end
  end

  @doc """
  The player's ray to its block reach (`getPlayerPOVHitResult`), through
  sources for an empty bucket (`content` `:empty`): `Valimc.Physics.Clip`'s hit.
  """
  def aim(player, content) do
    {ex, ey, ez} = eye = Interaction.eye(player)
    {vx, vy, vz} = Clip.view_vector(player.pitch, player.yaw)
    range = Interaction.block_range(player.game_mode.current)
    to = {ex + vx * range, ey + vy * range, ez + vz * range}
    states = read(player.dimension, Clip.cells(eye, to))
    Clip.clip(eye, to, if(content == :empty, do: :source_only, else: :none), &states[&1])
  end

  @doc "The state at `position` in `dimension`, from its section's owner (air when none answers)."
  def block_at(dimension, position), do: read(dimension, [position])[position] || 0

  # The cells' states, from their sections' owners; a cell no owner gives reads as air.
  defp read(dimension, cells) do
    cells
    |> Enum.group_by(fn {x, _, z} -> Grid.region_key(Grid.chunk_key(x, z)) end)
    |> Enum.reduce(%{}, fn {key, positions}, acc ->
      with {:ok, owner} <- World.existing_owner(Grid.section(dimension, key, :section)),
           {:ok, %{blocks: blocks}} <- Region.observe_blocks(owner, positions) do
        Map.merge(acc, blocks)
      else
        _ -> acc
      end
    end)
  end

  defp act(state, hand, stack, %{position: position, face: face}) do
    adjacent = step(position, face)

    case content(stack.item_id) do
      :empty ->
        with :ok <- room?(state.inventory, stack),
             {:ok, result} when result > 0 <- run(state, position, {:pickup, position}) do
          filled = ItemStack.new(Fluids.pickup_item(result))
          {:ok, filled(state.inventory, hand, stack, filled)}
        else
          # Nothing picked up (`{:ok, 0}`), no room or no owner: the bucket stays.
          _ -> :error
        end

      kind ->
        clicked = read(state.player.dimension, [position])[position] || 0

        target =
          if kind == 2 and BlockFacts.flag?(clicked, :liquid_container),
            do: position,
            else: adjacent

        secondary = Valimc.Player.Input.pressed?(state.player.input, :shift)
        action = {:empty, target, kind, adjacent, secondary}

        action =
          if Bucketable.type(stack.item_id), do: {:release, target, action, stack}, else: action

        case run(state, target, action) do
          {:ok, result} when result > 0 ->
            emptied =
              if state.inventory.infinite_materials, do: stack, else: ItemStack.new("bucket")

            {:ok, filled(state.inventory, hand, stack, emptied)}

          _ ->
            :error
        end
    end
  end

  defp run(state, {x, _, z} = position, action) do
    with true <- Valimc.Player.Mining.inside_border?(position),
         {:ok, owner} <-
           World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))) do
      Region.bucket(owner, action)
    end
  end

  defp step({x, y, z}, face) do
    {dx, dy, dz} = elem(@steps, face)
    {x + dx, y + dy, z + dz}
  end

  # A survival stack of empty buckets keeps one fewer and needs room for the filled one.
  defp room?(%{infinite_materials: true}, _), do: :ok
  defp room?(_, %{count: 1}), do: :ok

  defp room?(inventory, _stack) do
    {_, left} = Inventory.return_stack(inventory, ItemStack.new("water_bucket"))
    if left == nil or left.count == 0, do: :ok, else: :no_room
  end

  # `ItemUtils.createFilledResult`: creative players keep the held stack and
  # gain the new one if they have none like it; others use one of the held
  # stack, which becomes the new one when that was the last, else the new one
  # goes into the inventory.
  def filled(inventory, hand, stack, new) do
    slot = if hand == :main, do: 36 + inventory.selected, else: 45

    cond do
      new == stack ->
        inventory

      inventory.infinite_materials ->
        if Enum.any?(inventory.slots, fn {_, s} ->
             s.item_id == new.item_id and s.components == new.components
           end),
           do: inventory,
           else: elem(Inventory.return_stack(inventory, new), 0)

      stack.count == 1 ->
        Inventory.put(inventory, slot, new)

      true ->
        inventory
        |> Inventory.put(slot, %{stack | count: stack.count - 1})
        |> Inventory.return_stack(new)
        |> elem(0)
    end
  end

  @doc "Native capture's filled result; creative also adds a bucket, discarding overflow as native inventory does."
  def captured(inventory, hand, stack, new) do
    slot = if hand == :main, do: 36 + inventory.selected, else: 45

    if not inventory.infinite_materials and stack.count == 1 do
      {Inventory.put(inventory, slot, new), nil}
    else
      inventory =
        if inventory.infinite_materials,
          do: inventory,
          else: Inventory.put(inventory, slot, %{stack | count: stack.count - 1})

      {next, left} = Inventory.return_stack(inventory, new)
      {next, if(inventory.infinite_materials, do: nil, else: left)}
    end
  end
end
