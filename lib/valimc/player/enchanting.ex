defmodule Valimc.Player.Enchanting do
  @moduledoc """
  A player's enchanting table menu (VMC-038a, `EnchantmentMenu`), in the
  session the group hosts. Its item and lapis slots are the player's two
  menu inputs (`Inventory.payments`: saved with the inventory, given back or
  dropped when the menu closes); clicks go through the one click engine
  (`Valimc.Menus.Click`, `Menu.enchanting/0`).

  Whenever the inputs change the offers are made again (`slotsChanged`):
  the bookshelves around the table in the published blocks, then
  `Valimc.Menus.Enchanting.offers/3` from the player's enchantment seed; the
  menu's data slots carry the costs, the seed and the clues. A button
  (`clickMenuButton`) with its lapis and levels at hand enchants the item:
  the item, the lapis, the levels and the seed change in one callback, in
  the player's state, so a crash keeps all or none of them.
  """
  alias Valimc.Data.Blocks
  alias Valimc.Menus.{Click, Enchanting, Inventory, Menu}
  alias Valimc.Menus.Packets, as: MenuPackets
  alias Valimc.Player.{Experience, Items, ItemUse, Mining}
  alias Valimc.Protocol.{CombatPackets, Packets, Wire}
  alias Valimc.World

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @table Valimc.Protocol.Data.item_block(Valimc.Protocol.Data.item("enchanting_table"))
  @lapis Valimc.Protocol.Data.item("lapis_lazuli")
  @air Blocks.id("air")

  @doc "Open the table at `position` (its section's owner `owner`)."
  def open(state, position, owner, sequence) do
    id = rem(state.table_counter, 127) + 1

    inventory =
      state.inventory
      |> Inventory.cancel_drag()
      |> Map.update!(:payments, &(&1 || {nil, nil}))
      |> Inventory.advance()

    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()

    menu = %{
      kind: :enchanting,
      id: id,
      position: position,
      owner: owner,
      block: @table,
      offers: nil
    }

    state = %{state | inventory: inventory, table_menu: menu, table_counter: id}

    send_packets(state, [
      Packets.ack(sequence),
      MenuPackets.open_enchanting(id),
      MenuPackets.enchanting_inventory(id, inventory),
      Packets.cursor(inventory.carried)
    ])

    offer(state)
  end

  @doc "A click in the table's menu."
  def click(state, click) do
    case Click.plan(
           Menu.enchanting(),
           nil,
           state.inventory,
           click.action,
           click.slot,
           click.button
         ) do
      {:ok, nil, inventory, drops} ->
        state =
          case Items.drop(state, inventory, drops) do
            {:ok, state} -> state
            :error -> state
          end

        state |> sync() |> offer()

      {:error, _} ->
        sync(state)
    end
  end

  @doc "The menu's slots and cursor, sent again."
  def sync(state) do
    inventory = Inventory.advance(state.inventory)
    state = %{state | inventory: inventory}

    send_packets(state, [
      MenuPackets.enchanting_inventory(state.table_menu.id, inventory),
      Packets.cursor(inventory.carried)
    ])

    state
  end

  @doc """
  `slotsChanged`: the offers for the item in the menu, sent as the menu's
  data slots when they change.
  """
  def offer(%{table_menu: %{kind: :enchanting} = menu} = state) do
    {item, _lapis} = state.inventory.payments
    seed = seed(state)

    offers =
      if Enchanting.enchantable?(item),
        do: Enchanting.offers(item, bookcases(state, menu.position), seed),
        else: List.duplicate({0, nil}, 3)

    if offers == menu.offers do
      state
    else
      send_packets(state, properties(menu.id, offers, seed))
      %{state | table_menu: %{menu | offers: offers}}
    end
  end

  def offer(state), do: state

  # Costs, the seed (a data slot holds 16 bits), then the clues' enchantments
  # and levels.
  defp properties(id, offers, seed) do
    values =
      Enum.map(offers, &elem(&1, 0)) ++
        [seed] ++
        Enum.map(offers, fn {_, clue} -> if clue, do: elem(clue, 0), else: -1 end) ++
        Enum.map(offers, fn {_, clue} -> if clue, do: elem(clue, 1), else: -1 end)

    for {value, index} <- Enum.with_index(values), do: MenuPackets.property(id, index, value)
  end

  defp bookcases(state, position) do
    view = World.View.new(state.player.dimension)

    Enchanting.bookcases(position, fn cell ->
      case World.View.block(view, cell) do
        nil -> @air
        block_state -> Blocks.block_id(block_state)
      end
    end)
  end

  defp seed(state), do: Map.get(state.player, :enchantment_seed, 0)

  @doc """
  `ServerboundContainerButtonClickPacket` on the table (`clickMenuButton`):
  button 0, 1 or 2 enchants the item at its offer's cost for as much lapis
  and as many levels as its number, when the player has them (creative
  players need none); the seed changes, the table plays its sound.
  """
  def button(%{table_menu: %{kind: :enchanting, id: id}} = state, payload) do
    {container, rest} = Wire.take_varint(payload)
    {button, <<>>} = Wire.take_varint(rest)

    if container == id and button in 0..2, do: enchant(state, button), else: state
  end

  def button(state, _payload), do: state

  defp enchant(state, button) do
    menu = state.table_menu
    {item, lapis} = state.inventory.payments
    n = button + 1
    {cost, _} = Enum.at(menu.offers || List.duplicate({0, nil}, 3), button)
    infinite = state.inventory.infinite_materials
    level = state.player.progression.experience.level

    with true <- infinite or (lapis != nil and lapis.item_id == @lapis and lapis.count >= n),
         true <- cost > 0 and item != nil,
         true <- infinite or (level >= n and level >= cost),
         {:ok, enchanted} <- Enchanting.enchant(item, seed(state), button, cost) do
      lapis =
        cond do
          infinite -> lapis
          lapis.count > n -> %{lapis | count: lapis.count - n}
          true -> nil
        end

      # `onEnchantmentPerformed`: the levels go, a new seed comes.
      experience = Experience.add_levels(state.player.progression.experience, -n)
      seed = :rand.uniform(4_294_967_296) - 2_147_483_649
      player = state.player
      player = %{player | progression: %{player.progression | experience: experience}}
      player = Map.put(player, :enchantment_seed, seed)
      inventory = %{state.inventory | payments: {enchanted, lapis}} |> Inventory.advance()
      state = %{state | player: player, inventory: inventory}
      send_packets(state, [Valimc.Player.Packets.experience(experience)])
      state = sound(state, menu.position)
      state |> sync() |> offer()
    else
      _ -> state
    end
  end

  # `ENCHANTMENT_TABLE_USE` at the table, at 0.9 to 1.0.
  defp sound(state, {x, y, z}) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    pitch = :rand.uniform() * 0.1 + 0.9

    packet =
      CombatPackets.sound(
        "minecraft:block.enchantment_table.use",
        "block",
        {x + 0.5, y + 0.5, z + 0.5},
        1.0,
        pitch,
        seed
      )

    Valimc.Player.Movement.broadcast_player_packet(state, packet)
    send_packets(state, [packet])
    state
  end
end
