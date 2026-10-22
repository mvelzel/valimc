defmodule Valimc.Player.CreativeInventory do
  @moduledoc """
  The player's inventory screen (VMC-069, VMC-077i3): creative slot writes and
  drops, clicks in the inventory, its close and resynchronisation. What a
  click throws out drops at once (`Valimc.Player.Items`).
  """

  alias Valimc.Protocol.{InventoryClick, ItemStack, Packets, Wire}
  alias Valimc.Player.{Items, Menus}

  import Valimc.Net.Codec, only: [send_packets: 2, reject: 2]

  alias Valimc.{CreativeInput, Inventory}

  def creative_slot(state, <<slot::signed-16, payload::binary>>) do
    case ItemStack.decode(payload, :untrusted) do
      {:ok, stack} ->
        cond do
          not state.inventory.infinite_materials -> resync_inventory(state)
          slot < 0 -> creative_drop(state, stack)
          slot in 1..45 -> write_creative_slot(state, slot, stack)
          true -> resync_inventory(state)
        end

      {:unsupported, _names} ->
        send_packets(state, [
          Packets.chat("This item's components are not supported yet; slot restored")
        ])

        if slot in 1..45, do: correct_creative_slot(state, slot), else: resync_inventory(state)

      {:error, _} ->
        reject(state, "Malformed or invalid creative item")
    end
  end

  def creative_tick, do: Integer.floor_div(System.monotonic_time(:millisecond), 50)

  # Vanilla's drop throttle admits a creative drop, which conjures the stack.
  defp creative_drop(state, stack) do
    {result, input} = CreativeInput.charge(state.creative_input, creative_tick())
    state = %{state | creative_input: input}

    if result == :ok and stack != nil,
      do: Items.creative_drop(state, stack),
      else: resync_inventory(state)
  end

  def write_creative_slot(state, slot, stack, publish \\ true) do
    case Inventory.creative(state.inventory, slot, stack) do
      {:ok, inventory} ->
        if publish do
          updates = [Packets.container_slot(inventory.state_id, slot, stack)]

          updates =
            if slot in 1..4,
              do:
                updates ++
                  [
                    Packets.container_slot(
                      inventory.state_id,
                      0,
                      Inventory.crafting_result(inventory)
                    )
                  ],
              else: updates

          send_packets(state, updates)
        end

        %{state | inventory: inventory}

      {:error, _} ->
        resync_inventory(state)
    end
  end

  def correct_creative_slot(state, slot) do
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()

    send_packets(state, [
      Packets.container_slot(inventory.state_id, slot, Inventory.get(inventory, slot))
    ])

    %{state | inventory: inventory}
  end

  @doc false
  def resync_inventory(state) do
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()

    packet =
      case state.table_menu do
        %{kind: :chest, id: id, view: view} ->
          Packets.chest_inventory(id, view.rows, view.slots, inventory)

        %{kind: :cooking, id: id, view: view} ->
          Packets.cooking_inventory(id, view.cooking, inventory)

        %{id: id} ->
          Packets.table_inventory(id, inventory)

        nil ->
          Packets.inventory(inventory)
      end

    # Generic chest/table contents exclude the offhand, although native F input
    # predicts a change there. Correct its physical inventory address as well.
    offhand =
      if state.table_menu,
        do: [Packets.player_inventory_slot(40, Inventory.get(inventory, 45))],
        else: []

    properties =
      case state.table_menu do
        %{kind: :cooking, id: id, view: view} -> Packets.cooking_properties(id, view.cooking)
        _ -> []
      end

    send_packets(state, [packet, Packets.cursor(inventory.carried)] ++ offhand ++ properties)
    %{state | inventory: inventory}
  end

  @doc "The client closed its inventory screen: the cursor and grid return."
  def inventory_close(state), do: Menus.closed(state)

  def inventory_click(state, payload) do
    slots =
      case state.table_menu do
        %{kind: :chest, view: view} -> view.rows * 9 + 36
        %{kind: :cooking} -> 39
        _ -> 46
      end

    id = if state.table_menu, do: state.table_menu.id, else: 0

    case InventoryClick.decode(payload, id, slots) do
      {:ok, click} when state.table_menu != nil ->
        if click.container == state.table_menu.id,
          do: Menus.click(state, click),
          else: resync_inventory(state)

      {:ok, %{container: 0}} when state.player.game_mode.current == :spectator ->
        resync_inventory(state)

      {:ok, %{container: 0} = click} ->
        # The vanilla listener applies actions to current owner state even when
        # the reported state ID is stale. Predictions only guide replication.
        case Valimc.MenuClick.plan(
               Valimc.Menu.inventory(),
               nil,
               state.inventory,
               click.action,
               click.slot,
               click.button
             ) do
          {:ok, nil, inventory, []} ->
            send_packets(state, [Packets.inventory(inventory), Packets.cursor(inventory.carried)])
            %{state | inventory: inventory}

          {:ok, nil, inventory, stacks} ->
            Menus.thrown(state, inventory, stacks, click)

          {:error, _} ->
            send_packets(state, [
              Packets.chat("This inventory operation is not supported yet; state restored")
            ])

            resync_inventory(state)
        end

      {:ok, click} ->
        send_packets(state, [Packets.packet("container_close", Wire.varint(click.container))])
        resync_inventory(state)

      {:error, _} ->
        reject(state, "Malformed inventory click")
    end
  end
end
