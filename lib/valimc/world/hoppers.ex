defmodule Valimc.World.Hoppers do
  @moduledoc """
  A section's hoppers for one game tick (VMC-049a), as vanilla's
  `HopperBlockEntity` runs them: first each item entity lying in a hopper's
  bowl (`entityInside`, as the entity's own tick reaches it, in entity
  order), then each hopper's `pushItemsTick` in the order the hoppers were
  created (`Level.tickBlockEntities`): its cooldown counts down, and one off
  cooldown and enabled pushes an item into the container it faces (a
  furnace by face) and pulls one from the container above it, or an item
  entity at and above it unless a full block covers it; a move sets its
  cooldown to 8, and a hopper that receives into its empty inventory waits
  8 (7 when it already ticked).

  Pure over a context: the section's own container entries (which it
  changes), the group's other sections' entries (`foreign`: replacements
  are planned together and applied by that section in the same commit), the blocks
  (`block.(position)`, nil where unreadable), the items in entity order
  (none while a plan holds the store), the game tick, the hoppers that tick
  (in simulated chunks) and when each last ticked. A target outside the
  group is unreadable: regions keep loaded chunks of different groups at
  least 25 chunks apart (`Regionizer`), so nothing a hopper reaches lies in
  another group.
  """
  alias Valimc.Blocks.{Chest, CookingBlocks, ItemTransfer, Machine}
  alias Valimc.World.Containers
  alias Valimc.Data.BlockFacts
  alias Valimc.Protocol.Data

  @not_blocking MapSet.new(Data.tags()["minecraft:block"]["minecraft:does_not_block_hoppers"])
  @sides %{
    {0, -1, 0} => :down,
    {0, 1, 0} => :up,
    {0, 0, -1} => :north,
    {0, 0, 1} => :south,
    {-1, 0, 0} => :west,
    {1, 0, 0} => :east
  }
  @cooldown 8
  # An item's box: 0.25 wide, 0.25 tall, from its feet.
  @half 0.125
  @height 0.25

  @doc """
  Run a tick. `context`: `%{tick, entries, foreign, block, items, hoppers,
  ticked}` (`items` `[%{id, x, y, z, stack}]` in entity order, `hoppers`
  positions in tick order). Returns `%{entries, foreign, items, ticked}`:
  physical entries, including both halves of joined chests, and the changed
  item stacks by id (nil taken whole).
  """
  def tick(context) do
    acc = Map.put(context, :taken, %{})
    acc = Enum.reduce(context.items, acc, &entity_inside/2)

    acc = Enum.reduce(context.hoppers, acc, &push_items_tick/2)

    %{
      entries: acc.entries,
      foreign: acc.foreign,
      items: acc.taken,
      ticked: acc.ticked
    }
  end

  # `HopperBlock.entityInside` for each hopper cell the item's box is in
  # (`checkInsideBlocks`, its box deflated by 1e-5), x fastest, then y, z.
  defp entity_inside(item, acc) do
    {x0, y0, z0, x1, y1, z1} = box(item)
    e = 1.0e-5

    cells =
      for z <- floor(z0 + e)..floor(z1 - e)//1,
          y <- floor(y0 + e)..floor(y1 - e)//1,
          x <- floor(x0 + e)..floor(x1 - e)//1,
          do: {x, y, z}

    Enum.reduce(cells, acc, fn {x, y, z} = position, acc ->
      with %{kind: :hopper} <- acc.entries[position],
           current when current != nil <- live_stack(acc, item),
           true <-
             y1 > y + 0.6875 and y0 < y + 2 and x1 > x and x0 < x + 1 and z1 > z and
               z0 < z + 1 do
        try_move(acc, position, fn acc -> absorb(acc, position, item) end)
      else
        _ -> acc
      end
    end)
  end

  # `pushItemsTick`.
  defp push_items_tick(position, acc) do
    case acc.entries[position] do
      %{kind: :hopper, cooldown: cooldown} = hopper ->
        acc = %{acc | ticked: Map.put(acc.ticked, position, acc.tick)}

        if cooldown - 1 > 0 do
          put_entry(acc, position, %{hopper | cooldown: cooldown - 1})
        else
          acc
          |> put_entry(position, %{hopper | cooldown: 0})
          |> try_move(position, &suck(&1, position))
        end

      _ ->
        acc
    end
  end

  # `tryMoveItems`: push, then pull; a move puts it on cooldown.
  defp try_move(acc, position, action) do
    hopper = acc.entries[position]
    block = acc.block.(position)

    if hopper.cooldown <= 0 and block != nil and Machine.kind(block) == :hopper and
         Machine.enabled?(block) do
      {acc, pushed} =
        if ItemTransfer.empty?(hopper), do: {acc, false}, else: eject(acc, position, block)

      {acc, pulled} =
        if ItemTransfer.full?(acc.entries[position]), do: {acc, false}, else: action.(acc)

      if pushed or pulled,
        do: put_entry(acc, position, %{acc.entries[position] | cooldown: @cooldown}),
        else: acc
    else
      acc
    end
  end

  # `ejectItems`: one item of the first slot that fits into what it faces.
  defp eject(acc, position, block) do
    {dx, dy, dz} = step = Machine.facing(block)
    {x, y, z} = position
    target = {x + dx, y + dy, z + dz}
    side = Map.fetch!(@sides, negate(step))

    case container_at(acc, target) do
      nil ->
        {acc, false}

      {target_entry, target_block} ->
        if ItemTransfer.full?(target_entry, side) do
          {acc, false}
        else
          hopper = acc.entries[position]

          Enum.reduce_while(0..(tuple_size(hopper.slots) - 1), {acc, false}, fn slot, result ->
            case elem(hopper.slots, slot) do
              nil ->
                {:cont, result}

              stack ->
                case ItemTransfer.add(target_entry, %{stack | count: 1}, side, target_block) do
                  {next, nil, woke} ->
                    rest = if stack.count == 1, do: nil, else: %{stack | count: stack.count - 1}

                    acc =
                      acc
                      |> put_entry(position, %{hopper | slots: put_elem(hopper.slots, slot, rest)})
                      |> received(target, next, woke, position)

                    {:halt, {acc, true}}

                  _ ->
                    {:cont, result}
                end
            end
          end)
        end
    end
  end

  # `suckInItems`: from the container above, else the items at and above.
  defp suck(acc, position) do
    {x, y, z} = position
    above = {x, y + 1, z}

    case container_at(acc, above) do
      {source, source_block} ->
        hopper = acc.entries[position]

        case ItemTransfer.take(source, hopper, :down, source_block) do
          {:ok, source, hopper, woke} ->
            hopper =
              if woke,
                do:
                  ItemTransfer.woken_cooldown(
                    hopper,
                    from_hopper_skip(acc, position, source, above)
                  ),
                else: hopper

            acc = acc |> put_container(above, source) |> put_entry(position, hopper)
            {acc, true}

          :none ->
            {acc, false}
        end

      nil ->
        block = acc.block.(above)

        blocked =
          block != nil and BlockFacts.flag?(block, :full_collision) and
            not MapSet.member?(@not_blocking, Valimc.Data.Blocks.block_id(block))

        if block == nil or blocked do
          {acc, false}
        else
          Enum.reduce_while(items_at_and_above(acc, position), {acc, false}, fn item, {acc, _} ->
            case absorb(acc, position, item) do
              {acc, true} -> {:halt, {acc, true}}
              {acc, false} -> {:cont, {acc, false}}
            end
          end)
        end
    end
  end

  defp from_hopper_skip(acc, position, %{kind: :hopper}, source),
    do: Map.get(acc.ticked, position, 0) >= Map.get(acc.ticked, source, 0)

  defp from_hopper_skip(_acc, _position, _source, _at), do: false

  # `addItem(Container, ItemEntity)`: as much of the item as fits; true when
  # it all did (the item is gone).
  defp absorb(acc, position, item) do
    case live_stack(acc, item) do
      nil ->
        {acc, false}

      stack ->
        hopper = acc.entries[position]
        {next, rest, woke} = ItemTransfer.add(hopper, stack, nil)
        next = if woke, do: ItemTransfer.woken_cooldown(next, false), else: next
        acc = %{put_entry(acc, position, next) | taken: Map.put(acc.taken, item.id, rest)}
        {acc, rest == nil}
    end
  end

  defp live_stack(acc, item), do: Map.get(acc.taken, item.id, item.stack)

  # A container entry where its block holds it: the section's own, or a
  # sibling's.
  defp container_at(acc, position) do
    block = acc.block.(position)
    entry = acc.entries[position] || acc.foreign[position]

    cond do
      block == nil or entry == nil ->
        nil

      Chest.ordinary?(block) ->
        case Chest.positions(block, position, acc.block) do
          [_, _] = parts ->
            case Containers.chest_view(parts, &(acc.entries[&1] || acc.foreign[&1])) do
              {:ok, view} -> {view, block}
              _ -> nil
            end

          [_] ->
            {entry, block}
        end

      matches?(entry, block) ->
        {entry, block}

      true ->
        nil
    end
  end

  defp matches?(%{cooking: _, kind: kind}, block), do: CookingBlocks.kind(block) == kind
  defp matches?(%{rows: 3}, block), do: Valimc.Blocks.block_entity(block) == :chest
  defp matches?(%{kind: kind, slots: _}, block), do: Machine.kind(block) == kind
  defp matches?(_, _), do: false

  # What a container received: a hopper that was empty waits (one tick less
  # when it ticked no earlier than the hopper that gave it).
  defp received(acc, target, entry, woke, from) do
    if Map.has_key?(acc.entries, target) do
      entry =
        if woke and match?(%{kind: :hopper}, entry),
          do:
            ItemTransfer.woken_cooldown(
              entry,
              Map.get(acc.ticked, target, 0) >= Map.get(acc.ticked, from, 0)
            ),
          else: entry

      put_container(acc, target, entry)
    else
      put_container(acc, target, entry)
    end
  end

  defp put_container(acc, _position, %{parts: _} = view) do
    Enum.reduce(Containers.chest_parts(view), acc, fn {at, slots}, acc ->
      entry = acc.entries[at] || acc.foreign[at]
      put_container(acc, at, %{entry | slots: slots})
    end)
  end

  defp put_container(acc, position, entry) do
    if Map.has_key?(acc.entries, position),
      do: put_entry(acc, position, entry),
      else: %{acc | foreign: Map.put(acc.foreign, position, entry)}
  end

  defp put_entry(acc, position, entry),
    do: %{acc | entries: Map.put(acc.entries, position, entry)}

  # `getItemsAtAndAbove`: the items whose box meets the hopper's suck box,
  # as the level's entity sections list them (by section, then entity order).
  defp items_at_and_above(acc, {x, y, z}) do
    acc.items
    |> Enum.filter(fn item ->
      {x0, y0, z0, x1, y1, z1} = box(item)

      live_stack(acc, item) != nil and x1 > x and x0 < x + 1 and z1 > z and z0 < z + 1 and
        y1 > y + 0.6875 and y0 < y + 2
    end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} -> {section_order(item), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  # The order the level's entity sections are visited in
  # (`EntitySectionStorage.forEachAccessibleNonEmptySection`): by section x,
  # then by `SectionPos.asLong` within it (z, then y, each as unsigned bits).
  defp section_order(%{x: x, y: y, z: z}) do
    import Bitwise
    {floor(x) >>> 4, floor(z) >>> 4 &&& 0x3FFFFF, floor(y) >>> 4 &&& 0xFFFFF}
  end

  defp box(%{x: x, y: y, z: z}), do: {x - @half, y, z - @half, x + @half, y + @height, z + @half}

  defp negate({x, y, z}), do: {-x, -y, -z}

  @doc """
  Apply a sibling's inserts to `entries` (`{position, stack, side,
  from_ticked}`): `{entries, spilled}`, where `spilled` are the stacks that no
  longer fit (`[{position, stack}]`), which the caller drops there rather
  than lose. `block` reads this section's blocks; `ticked` its hoppers'.
  """
  def receive(entries, inserts, block, ticked) do
    Enum.reduce(inserts, {entries, []}, fn {position, stack, side, from_ticked},
                                           {entries, spilled} ->
      case entries[position] do
        nil ->
          {entries, [{position, stack} | spilled]}

        entry ->
          {next, rest, woke} = ItemTransfer.add(entry, stack, side, block.(position))

          next =
            if woke and match?(%{kind: :hopper}, next),
              do:
                ItemTransfer.woken_cooldown(
                  next,
                  from_ticked != nil and Map.get(ticked, position, 0) >= from_ticked
                ),
              else: next

          spilled = if rest, do: [{position, rest} | spilled], else: spilled
          {Map.put(entries, position, next), spilled}
      end
    end)
    |> then(fn {entries, spilled} -> {entries, Enum.reverse(spilled)} end)
  end
end
