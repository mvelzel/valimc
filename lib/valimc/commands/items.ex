defmodule Valimc.Commands.Items do
  @moduledoc """
  `/item replace entity <targets> <slots> with <item> [<count>]`
  (`ItemCommands`, VMC-085): each target's slots in the range (`SlotRanges`)
  get a copy of the item. A player's are its inventory's (`Player.getSlot`:
  hotbar, inventory, container, weapon and armour), a mob's its equipment.
  A slot an entity does not have is skipped; no slot taken at all is
  `commands.item.target.failed`. `/item replace block`, `… from` and
  `/item modify` wait for block containers and loot modifiers.
  """
  alias Valimc.Commands.{Remote, Source, Targets}
  alias Valimc.Protocol.ItemStack
  alias Valimc.Text
  alias Valimc.Text.{Error, Reader}
  alias Valimc.World

  @doc "The vanilla paths ValiMC runs."
  def paths,
    do: [
      ~w(item replace entity target slots with item),
      ~w(item replace entity target slots with item count)
    ]

  @equipment %{
    "weapon" => [:mainhand],
    "weapon.mainhand" => [:mainhand],
    "weapon.offhand" => [:offhand],
    "weapon.*" => [:mainhand, :offhand],
    "armor.head" => [:head],
    "armor.chest" => [:chest],
    "armor.legs" => [:legs],
    "armor.feet" => [:feet],
    "armor.body" => [:body],
    "armor.*" => [:head, :chest, :legs, :feet, :body],
    "saddle" => [:saddle]
  }

  # Inventory slot numbers (`Inventory.getItem` indices: hotbar 0–8, the
  # rest 9–35) by range, before they become menu slots.
  defp inventory("hotbar.*"), do: Enum.to_list(0..8)
  defp inventory("inventory.*"), do: Enum.to_list(9..35)
  defp inventory("container.*"), do: Enum.to_list(0..35)
  defp inventory("hotbar." <> n), do: index(n, 0..8, 0)
  defp inventory("inventory." <> n), do: index(n, 0..26, 9)
  defp inventory("container." <> n), do: index(n, 0..35, 0)
  defp inventory(_), do: nil

  defp index(n, range, offset) do
    case Integer.parse(n) do
      {i, ""} -> if i in range, do: [i + offset]
      _ -> nil
    end
  end

  @doc """
  `SlotsArgument`: the range's name up to the next space, `slot.unknown`
  for one vanilla does not have.
  """
  def parse_slots(reader) do
    start = reader.cursor
    {name, reader} = Reader.take_while(reader, &(&1 != ?\s))

    if name in vanilla_names(),
      do: {name, reader},
      else: Error.fail_at!("slot.unknown", [name], %{reader | cursor: start})
  end

  # `SlotRanges`' names in 26.3.
  defp vanilla_names do
    numbered = [
      {"container", 53},
      {"hotbar", 8},
      {"inventory", 26},
      {"enderchest", 26},
      {"mob.inventory", 7},
      {"villager", 7},
      {"horse", 14},
      {"player.crafting", 3}
    ]

    Map.keys(@equipment) ++
      for(
        {prefix, last} <- numbered,
        name <- ["#{prefix}.*" | for(i <- 0..last, do: "#{prefix}.#{i}")],
        do: name
      ) ++
      ~w(horse.saddle horse.chest player.cursor contents)
  end

  @doc "`/item replace entity <targets> <slots> with <item> [<count>]`."
  def item(%{"target" => selector, "slots" => slots, "item" => input} = arguments, source) do
    count = Map.get(arguments, "count", 1)

    stack = %ItemStack{
      ItemStack.new(input.item, count)
      | components: input.components,
        removed: input.removed
    }

    targets = Targets.required_any(source, selector)
    equipment = Map.get(@equipment, slots)
    menu = inventory(slots)

    if equipment == nil and menu == nil,
      do: Error.refuse!("The slot range #{slots} is not supported yet")

    {bodies, players} = Enum.split_with(targets, &match?(%{kind: :body}, &1))

    changed =
      Enum.flat_map(bodies, &body_slots(&1, equipment || [], stack)) ++
        player_slots(players, menu_slots(menu, equipment), stack)

    item = Valimc.Protocol.ItemData.display_name(stack)

    case changed do
      [] ->
        Error.fail!("commands.item.target.failed.known_item", [item])

      [{target, n}] ->
        feedback(source, "commands.item.entity.replace.success.single.known_item", [
          n,
          Source.display_name(target),
          item
        ])

      many ->
        feedback(source, "commands.item.entity.replace.success.multiple.known_item", [
          length(many),
          item
        ])
    end

    length(changed)
  end

  defp feedback(source, key, args),
    do: Valimc.Commands.Feedback.success(source, Text.translatable(key, args))

  # A player's menu slots for the range: inventory numbers, else equipment.
  defp menu_slots(numbers, _equipment) when is_list(numbers),
    do: Enum.map(numbers, &if(&1 < 9, do: 36 + &1, else: &1))

  defp menu_slots(nil, equipment) do
    for slot <- equipment,
        menu = %{mainhand: :selected, offhand: 45, head: 5, chest: 6, legs: 7, feet: 8}[slot],
        do: menu
  end

  defp player_slots(_players, [], _stack), do: []
  defp player_slots([], _slots, _stack), do: []

  defp player_slots(players, slots, stack) do
    for {target, n} <- Remote.run_all!(players, fn _ -> {:replace_slots, slots, stack} end),
        is_integer(n) and n > 0,
        do: {target, n}
  end

  defp body_slots(body, slots, stack) do
    with {:ok, owner} <- World.existing_owner(body.section) do
      n =
        Enum.count(
          slots,
          &(Valimc.World.Region.set_entity_slot(owner, body.uuid, &1, stack) == :ok)
        )

      if n > 0, do: [{body, n}], else: []
    else
      _ -> []
    end
  end
end
