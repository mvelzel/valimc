defmodule Valimc.Player.CreativeInventory do
  @moduledoc "Inventory edits inside the connection: creative slot writes and drops, clicks, closes and resynchronisation (VMC-069)."

  alias Valimc.Protocol.{
    InventoryClick,
    ItemStack,
    Packets,
    Wire
  }

  alias Valimc.Player.Transfers

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{CreativeInput, Inventory, PlayerStore}
  alias Valimc.Player.State, as: PlayerState

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def creative_slot(state, <<slot::signed-16, payload::binary>>) do
    case ItemStack.decode(payload, :untrusted) do
      {:ok, stack} ->
        cond do
          not state.inventory.infinite_materials ->
            resync_inventory(state)

          state.table_closing or state.table_job != nil ->
            resync_inventory(state)

          state.recovery != nil and not creative_pending?(state) ->
            resync_inventory(state)

          slot < 0 ->
            creative_drop(state, stack, byte_size(payload) + 2)

          slot in 1..45 ->
            if state.recovery == nil and state.creative_input.queued == 0,
              do: write_creative_slot(state, slot, stack),
              else: enqueue_creative(state, {:slot, slot, stack}, byte_size(payload) + 2)

          true ->
            resync_inventory(state)
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

  def creative_pending?(%{recovery: %{mode: :play, plan: %{kind: :creative_creation}}}),
    do: true

  def creative_pending?(_), do: false

  # Do not overwrite valid client predictions with an earlier creative snapshot
  # while their following slot updates are still deferred.
  def sync_creative_result(%{life_stage: stage} = state) when stage != :alive, do: state

  def sync_creative_result(state) do
    if creative_pending?(state) or state.creative_input.queued > 0,
      do: state,
      else: resync_inventory(state)
  end

  def sync_recovery_inventory(
        %{table_menu: %{kind: kind}} = state,
        %{intent: %{outbox: %{kind: :container}}}
      )
      when kind in [:chest, :cooking] do
    # Sealing changes player items; refresh storage before publishing a combined
    # menu so the client never sees new player items beside the previous storage.
    Valimc.Player.Menus.request_table(state, :refresh, state.table_menu.position, nil)
  end

  def sync_recovery_inventory(state, _), do: sync_creative_result(state)

  def creative_drop(state, stack, bytes) do
    {result, input} = CreativeInput.charge(state.creative_input, creative_tick())
    state = %{state | creative_input: input}

    if result == :ok and stack != nil do
      case Valimc.PlayerDrops.records(state.player, [stack], :directed) do
        {:ok, key, [record]} -> enqueue_creative(state, {:create, key, record}, bytes)
        {:error, _} -> resync_inventory(state)
      end
    else
      resync_inventory(state)
    end
  end

  def enqueue_creative(state, command, bytes) do
    case CreativeInput.push(state.creative_input, command, bytes) do
      {:ok, input} ->
        drain_creative(%{state | creative_input: input})

      {:error, _} ->
        send_packets(state, [Packets.chat("Creative input queue is full; inventory restored")])
        resync_inventory(state)
    end
  end

  def drain_creative(state), do: drain_creative(state, 64)
  def drain_creative(state, _) when state.recovery != nil or state.save_ref != nil, do: state
  def drain_creative(state, _) when state.creative_input.queued == 0, do: state

  def drain_creative(state, _) when not state.inventory.infinite_materials,
    do: resync_inventory(%{state | creative_input: CreativeInput.clear(state.creative_input)})

  def drain_creative(state, 0) do
    if not state.creative_drain_scheduled, do: send(state.connection, :drain_creative)
    %{state | creative_drain_scheduled: true}
  end

  def drain_creative(state, budget) do
    {:ok, command, input} = CreativeInput.pop(state.creative_input)
    state = %{state | creative_input: input}

    case command do
      {:slot, slot, stack} ->
        state
        |> write_creative_slot(slot, stack, state.creative_input.queued == 0)
        |> drain_creative(budget - 1)

      {:create, key, record} ->
        ref = make_ref()

        recovery = %{
          Transfers.new_recovery(state, :play, :prepare, nil)
          | ref: ref,
            plan: %{
              kind: :creative_creation,
              key: key,
              records: [record],
              inventory: state.inventory
            }
        }

        PlayerStore.prepare_creative_drop(
          state.player_store,
          state.store_fence,
          PlayerState.capture(state.player, state.inventory),
          key,
          record,
          ref
        )

        %{state | recovery: recovery, inventory: Inventory.cancel_drag(state.inventory)}
    end
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
  def resync_inventory(%{table_closing: true} = state), do: state

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

  def inventory_close(state) do
    Valimc.Player.Menus.continue_table_close(%{state | crafting_repeat: nil, table_closing: true})
  end

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
        if click.container == state.table_menu.id do
          if state.table_queued >= 64, do: reject(state, "Too many pending table actions")

          Valimc.Player.Menus.drain_table_clicks(%{
            state
            | table_queue: :queue.in(click, state.table_queue),
              table_queued: state.table_queued + 1
          })
        else
          resync_inventory(state)
        end

      {:ok, %{container: 0}} when inventory_pending(state) ->
        resync_inventory(state)

      {:ok, %{container: 0}} when state.player.game_mode.current == :spectator ->
        resync_inventory(state)

      {:ok, %{container: 0} = click} ->
        # The vanilla listener applies actions to current owner state even when
        # the reported state ID is stale. Predictions only guide replication.
        menu = Valimc.Menu.inventory()

        case Valimc.MenuClick.plan(
               menu,
               nil,
               state.inventory,
               click.action,
               click.slot,
               click.button
             ) do
          {:ok, nil, inventory, []} ->
            send_packets(state, [Packets.inventory(inventory), Packets.cursor(inventory.carried)])
            %{state | inventory: inventory}

          {:ok, nil, inventory, [_ | _] = stacks} ->
            Valimc.Player.Menus.start_click_transfer(state, inventory, stacks, click)

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
