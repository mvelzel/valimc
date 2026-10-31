defmodule Valimc.Player.Anvil do
  @moduledoc """
  A player's anvil and grindstone menus (VMC-038b, `AnvilMenu` and
  `GrindstoneMenu`), in the session the group hosts. The two inputs are the
  player's menu inputs (`Inventory.payments`: saved with the inventory,
  given back or dropped when the menu closes); clicks on them and the
  inventory go through the one click engine; the result (window slot 2) is
  derived from the inputs (`Valimc.Menus.Anvil`) and taken here.

  Taking an anvil's result pays its cost in levels (creative players pay
  none), uses up the input and the addition (or just the repair materials
  it used), and with a chance of 12% wears the anvil a step (chipped,
  damaged, gone) with its sound; a rename (`rename_item`) changes the
  result. Taking a grindstone's result uses up both inputs and leaves
  experience orbs at the grindstone. The inputs, the result and the levels
  change in one session callback, in the player's state.
  """
  alias Valimc.Data.Blocks
  alias Valimc.Entity.ExperienceOrbs
  alias Valimc.Menus.{Anvil, Click, Inventory, Menu}
  alias Valimc.Menus.Packets, as: MenuPackets
  alias Valimc.Player.{Experience, Items, ItemUse, Mining}
  alias Valimc.Protocol.{Packets, Wire}

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @anvils ["anvil", "chipped_anvil", "damaged_anvil"]

  @doc "Open the `kind` (`:anvil` or `:grindstone`) at `position`."
  def open(state, kind, position, owner, sequence) do
    id = rem(state.table_counter, 127) + 1

    inventory =
      state.inventory
      |> Inventory.cancel_drag()
      |> Map.update!(:payments, &(&1 || {nil, nil}))
      |> Inventory.advance()

    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()
    block = Valimc.World.View.block(Valimc.World.View.new(state.player.dimension), position)

    menu = %{
      kind: kind,
      id: id,
      position: position,
      owner: owner,
      block: block,
      name: nil,
      outcome: nil
    }

    state = %{state | inventory: inventory, table_menu: menu, table_counter: id}
    send_packets(state, [Packets.ack(sequence), MenuPackets.open_workstation(id, kind)])
    state |> outcome() |> sync()
  end

  # The result and its cost for the inputs now.
  defp outcome(%{table_menu: %{kind: :anvil} = menu, inventory: inventory} = state) do
    {input, addition} = inventory.payments
    outcome = Anvil.result(input, addition, menu.name, inventory.infinite_materials)

    if menu.outcome == nil or outcome.cost != menu.outcome.cost,
      do: send_packets(state, [MenuPackets.property(menu.id, 0, outcome.cost)])

    %{state | table_menu: %{menu | outcome: outcome}}
  end

  defp outcome(%{table_menu: %{kind: :grindstone} = menu, inventory: inventory} = state) do
    {input, addition} = inventory.payments
    %{state | table_menu: %{menu | outcome: %{result: Anvil.grind(input, addition)}}}
  end

  @doc "The menu's slots and cursor, sent again."
  def sync(state) do
    inventory = Inventory.advance(state.inventory)
    state = %{state | inventory: inventory}
    menu = state.table_menu

    send_packets(state, [
      MenuPackets.workstation_inventory(menu.id, inventory, menu.outcome.result),
      Packets.cursor(inventory.carried)
    ])

    state
  end

  @doc "A click in the menu: the result's own, or the engine's for the rest."
  def click(%{table_menu: menu} = state, %{slot: 2} = click) do
    result = menu.outcome.result

    cond do
      result == nil or not takeable?(state) ->
        sync(state)

      click.action == :pickup and click.button in [0, 1] and state.inventory.carried == nil ->
        state
        |> put_inventory(%{state.inventory | carried: result})
        |> taken()

      click.action == :quick_move ->
        case Inventory.pickup_stack(state.inventory, result) do
          {:ok, inventory, nil, _} -> state |> put_inventory(inventory) |> taken()
          _ -> sync(state)
        end

      true ->
        sync(state)
    end
  end

  def click(%{table_menu: menu} = state, click) do
    case Click.plan(
           %Menu{kind: menu.kind},
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

        state |> outcome() |> sync()

      {:error, _} ->
        sync(state)
    end
  end

  defp put_inventory(state, inventory), do: %{state | inventory: inventory}

  # `AnvilMenu.mayPickup`: the cost is due and payable.
  defp takeable?(%{table_menu: %{kind: :anvil, outcome: outcome}} = state) do
    outcome.cost > 0 and
      (state.inventory.infinite_materials or
         state.player.progression.experience.level >= outcome.cost)
  end

  defp takeable?(_state), do: true

  # `onTake`.
  defp taken(%{table_menu: %{kind: :anvil, outcome: outcome} = menu} = state) do
    {_input, addition} = state.inventory.payments
    infinite = state.inventory.infinite_materials

    state =
      if infinite do
        state
      else
        experience = Experience.add_levels(state.player.progression.experience, -outcome.cost)
        send_packets(state, [Valimc.Player.Packets.experience(experience)])
        put_in(state.player.progression.experience, experience)
      end

    inventory = %{state.inventory | payments: {nil, Anvil.taken(addition, outcome)}}
    state = %{state | inventory: inventory, table_menu: %{menu | name: nil}}
    state = if infinite, do: event(state, 1030), else: wear(state)
    state |> outcome() |> sync()
  end

  defp taken(%{table_menu: %{kind: :grindstone} = menu} = state) do
    {input, addition} = state.inventory.payments
    amount = Anvil.grind_experience([input, addition])
    {x, y, z} = menu.position

    if amount > 0 do
      {:ok, parts} = ExperienceOrbs.split(amount)
      orbs = ExperienceOrbs.orbs({x + 0.5, y + 0.5, z + 0.5}, parts)
      Items.spawn(state, orbs)
    end

    state = %{state | inventory: %{state.inventory | payments: {nil, nil}}}
    state |> event(1042) |> outcome() |> sync()
  end

  # Taken in survival: one time in about eight the anvil wears a step.
  defp wear(%{table_menu: menu} = state) do
    view = Valimc.World.View.new(state.player.dimension)

    with true <- :rand.uniform() < 0.12,
         block_state when block_state != nil <- Valimc.World.View.block(view, menu.position),
         name when name in @anvils <- Blocks.name(Blocks.block_id(block_state)) do
      {next, event} =
        case name do
          "anvil" -> {"chipped_anvil", 1030}
          "chipped_anvil" -> {"damaged_anvil", 1030}
          _ -> {nil, 1029}
        end

      replacement =
        if next,
          do: Blocks.state(next, Map.new(Blocks.properties(block_state))),
          else: Blocks.default_state("air")

      _ =
        Valimc.Player.Sleep.write(
          state.player.dimension,
          %{menu.position => replacement},
          %{menu.position => block_state}
        )

      state = event(state, event)
      if next, do: state, else: Valimc.Player.Menus.close(state)
    else
      _ -> event(state, 1030)
    end
  end

  # The anvil's use (1030), break (1029) or the grindstone's (1042).
  defp event(state, type) do
    packet = Packets.level_event(type, state.table_menu.position, 0)
    Valimc.Player.Movement.broadcast_player_packet(state, packet)
    send_packets(state, [packet])
    state
  end

  @doc "`ServerboundRenameItemPacket` (`setItemName`): the result's new name."
  def rename(%{table_menu: %{kind: :anvil} = menu} = state, payload) do
    {name, <<>>} = Wire.take_string(payload)

    case Anvil.valid_name(name) do
      nil -> state
      ^name when name == menu.name -> state
      valid -> %{state | table_menu: %{menu | name: valid}} |> outcome() |> sync()
    end
  end

  def rename(state, _payload), do: state
end
