defmodule Valimc.Player.Menus do
  @moduledoc """
  A player's block menus (VMC-069, VMC-077i3): crafting tables, chests,
  barrels, furnaces, hoppers, droppers and dispensers. The block's owner is the player's own group, so opening, every
  click and each refresh is a plain call to it (`Region.menu/4`,
  `Region.container_click/6`) answered at once; a crafting table's clicks
  stay in the session, and what a click or a close throws out drops at once
  (`Valimc.Player.Items`).

  An open container view is subscribed at its owner: another player's click,
  a furnace's progress or the block's removal arrive as events that mark the
  view for a refresh, check it, or close it.
  """
  alias Valimc.Data.Grid
  alias Valimc.Protocol.{Data, ItemStack, Packets, Wire}
  alias Valimc.Player.{CreativeInventory, Items, ItemUse, Mining}
  alias Valimc.Menus.{Inventory, Menu, Click}
  alias Valimc.Player.Input
  alias Valimc.World
  alias Valimc.World.Region

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @containers Valimc.Menus.MenuAccess.containers()
  @openers Valimc.Menus.MenuAccess.openers()

  # A crafting gesture repeats while its result stays the same (vanilla's
  # `quickMoveStack` loop), at most this often per click.
  @repeats 64

  @doc "Use of the block at `position` (a `use_item_on`): open its menu, or place against it."
  def use_block(state, position, request) do
    # Beds and respawn anchors (VMC-040a) come first.
    case Valimc.Player.SpawnBlocks.use(state, position, request) do
      {:used, state} -> acknowledge_table_use(state, request)
      :pass -> use_menu(state, position, request)
    end
  end

  defp use_menu(state, {x, _, z} = position, request) do
    section = Grid.section(state.player.dimension, Grid.chunk_key(x, z))

    with {:ok, owner} <- World.existing_owner(section),
         decision when not is_tuple(decision) or elem(decision, 0) != :error <-
           Region.menu(
             owner,
             state.connection,
             position,
             Map.put(grant(state, :open, request.hand), :face, request.face)
           ) do
      case decision do
        :open ->
          open_table_menu(state, position, owner, request.sequence)

        :sheared ->
          state
          |> Valimc.Player.Placement.wear_held(request.hand, 1)
          |> acknowledge_table_use(request)

        :pass ->
          Valimc.Player.Placement.execute_placement(state, request)

        # A fence took the player's leashed mobs (VMC-043c3): the server swings.
        :swing ->
          action = if request.hand == :off, do: 3, else: 0

          Valimc.Player.Movement.broadcast_player_packet(
            state,
            Valimc.Protocol.EntityPackets.animate(state.player.entity_id, action)
          )

          acknowledge_table_use(state, request)

        {kind, block, view} when kind in @containers ->
          open_container_menu(state, kind, position, owner, block, view, request.sequence)

        _ ->
          acknowledge_table_use(state, request)
      end
    else
      _ -> acknowledge_table_use(state, request)
    end
  end

  def acknowledge_table_use(state, request) do
    send_packets(state, [Packets.ack(request.sequence)])
    CreativeInventory.resync_inventory(state)
  end

  # What a grant tells the owner of the player (`Valimc.Menus.MenuAccess`).
  defp grant(state, kind, hand \\ :main) do
    grant = %{
      kind: kind,
      mode: state.player.game_mode.current,
      eye: Valimc.Living.Interaction.eye(state.player),
      expires: System.monotonic_time(:millisecond) + 250,
      hand: hand,
      yaw: state.player.yaw,
      # Whose leashed mobs a fence takes (VMC-043c3).
      player: state.player.uuid,
      secondary: Input.pressed?(state.player.input, :shift),
      main: Inventory.held(state.inventory, :main) != nil,
      off: Inventory.held(state.inventory, :off) != nil,
      main_item:
        case Inventory.held(state.inventory, :main) do
          %{item_id: id} -> id
          nil -> nil
        end,
      item:
        case Inventory.held(state.inventory, hand) do
          %{item_id: id} -> id
          nil -> nil
        end,
      feet: {state.player.x, state.player.y, state.player.z},
      # The opener's luck, which loot an opened chest unpacks reads.
      luck: Valimc.Living.Attributes.luck(state.player.living.effects)
    }

    case state.table_menu do
      nil ->
        grant

      menu ->
        Map.merge(grant, %{
          menu: menu.kind,
          view_ref: menu[:view_ref],
          revision:
            if(
              menu.kind in @containers and
                kind not in [:refresh, :subscribe],
              do: menu.view.revision
            )
        })
    end
  end

  defp open_table_menu(state, position, owner, sequence) do
    id = rem(state.table_counter, 127) + 1

    inventory =
      %{Inventory.cancel_drag(state.inventory) | table_inputs: Tuple.duplicate(nil, 9)}
      |> Inventory.advance()

    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()

    send_packets(state, [
      Packets.ack(sequence),
      Valimc.Menus.Packets.open_table(id),
      Valimc.Menus.Packets.table_inventory(id, inventory),
      Packets.cursor(inventory.carried)
    ])

    %{
      state
      | inventory: inventory,
        table_menu: %{kind: :table, id: id, position: position, owner: owner},
        table_counter: id
    }
  end

  defp open_container_menu(state, kind, position, owner, block, view, sequence) do
    # Opening a chest or barrel angers the piglins that see it (VMC-043d,
    # `PiglinAi.angerNearbyPiglins`).
    if kind in @openers, do: Region.mob_event(owner, {:anger, {:player, state.player.uuid}, true})

    id = rem(state.table_counter, 127) + 1
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()
    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()

    {open, content, properties} =
      case kind do
        :chest ->
          {Valimc.Menus.Packets.open_chest(id, view.rows),
           Valimc.Menus.Packets.chest_inventory(id, view.rows, view.slots, inventory), []}

        :storage ->
          {Valimc.Menus.Packets.open_storage(id, view.kind),
           Valimc.Menus.Packets.storage_inventory(id, view.kind, view.slots, inventory), []}

        machine when machine in [:hopper, :dispenser] ->
          {Valimc.Menus.Packets.open_machine(id, view.kind),
           Valimc.Menus.Packets.machine_inventory(id, view.kind, view.slots, inventory), []}

        :cooking ->
          {Valimc.Menus.Packets.open_cooking(id, view.kind),
           Valimc.Menus.Packets.cooking_inventory(id, view.cooking, inventory),
           Valimc.Menus.Packets.cooking_properties(id, view.cooking)}
      end

    send_packets(
      state,
      [Packets.ack(sequence), open, content, Packets.cursor(inventory.carried)] ++ properties
    )

    state = %{
      state
      | inventory: inventory,
        table_menu: %{
          kind: kind,
          id: id,
          position: position,
          owner: owner,
          block: block,
          view: view,
          view_ref: make_ref(),
          dirty: false,
          progress_dirty: false,
          opener: kind in @openers and state.player.game_mode.current != :spectator
        },
        table_counter: id
    }

    subscribe(state)
  end

  # The view subscribes at the container's owner, which shows the chest open.
  defp subscribe(state) do
    menu = state.table_menu

    case Region.menu(menu.owner, state.connection, menu.position, grant(state, :subscribe)) do
      :valid -> refreshed(state, :valid)
      {kind, _, _} = decision when kind == menu.kind -> refreshed(state, decision)
      _ -> close(state)
    end
  end

  @doc "Whether the player may still use its open menu (vanilla's `stillValid`)."
  def table_player_valid?(%{table_menu: nil}), do: false

  def table_player_valid?(state) do
    menu = state.table_menu

    block =
      if menu.kind == :table, do: Data.item_block(Data.item("crafting_table")), else: menu.block

    state.life_stage == :alive and not state.teleport_pending and
      Input.loaded?(state.player.input) and
      Valimc.Menus.MenuAccess.valid_view?(
        menu.kind,
        block,
        state.player.game_mode.current,
        Valimc.Living.Interaction.eye(state.player),
        menu.position
      )
  end

  @doc """
  Check the open menu: close it once the player cannot use it or its block's
  owner changed; refresh a container view that changed.
  """
  def check_table_menu(%{table_menu: nil} = state), do: state

  def check_table_menu(%{table_menu: %{kind: :merchant}} = state),
    do: Valimc.Player.Merchant.check(state)

  def check_table_menu(%{table_menu: %{kind: kind} = menu} = state)
      when kind in @containers do
    opener = kind in @openers and state.player.game_mode.current != :spectator

    cond do
      not table_player_valid?(state) or not current_owner?(state, menu) ->
        close(state)

      menu.opener != opener ->
        retire_container_view(state)
        subscribe(%{state | table_menu: %{menu | view_ref: make_ref(), opener: opener}})

      menu.dirty ->
        refresh(state, :refresh)

      menu.progress_dirty ->
        refresh(state, :progress)

      true ->
        state
    end
  end

  def check_table_menu(state) do
    if table_player_valid?(state) and current_owner?(state, state.table_menu),
      do: state,
      else: close(state)
  end

  defp current_owner?(state, %{position: {x, _, z}, owner: owner}),
    do:
      World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))) ==
        {:ok, owner}

  @doc "Another change to the open container (`container_changed`): it refreshes."
  def changed(%{table_menu: menu} = state, revision) do
    if is_map(menu.view.revision) or revision > menu.view.revision,
      do: check_table_menu(%{state | table_menu: %{menu | dirty: true}}),
      else: state
  end

  @doc "A furnace's progress moved (`container_progress`)."
  def progressed(%{table_menu: menu} = state, generation) do
    if generation > Map.get(menu.view, :generation, 0),
      do: check_table_menu(%{state | table_menu: %{menu | progress_dirty: true}}),
      else: state
  end

  defp refresh(state, kind) do
    menu = state.table_menu

    case Region.menu(menu.owner, state.connection, menu.position, grant(state, :refresh)) do
      {:cooking, _block, view} when kind == :progress and menu.kind == :cooking ->
        if view.revision == menu.view.revision and view.cooking.slots == menu.view.cooking.slots do
          send_packets(state, Valimc.Menus.Packets.cooking_properties(menu.id, view.cooking))
          %{state | table_menu: %{menu | view: view, progress_dirty: false}}
        else
          refreshed(state, {:cooking, menu.block, view})
        end

      :valid ->
        refreshed(state, :valid)

      {menu_kind, _, _} = decision when menu_kind == menu.kind ->
        refreshed(state, decision)

      {:error, {:retry, _}} ->
        # A joined half may be planning a write while redstone or another
        # viewer changes its contents. Keep the subscription and refresh on
        # the next player tick, including after a click that could not run.
        %{state | table_menu: %{menu | dirty: true}}

      _ ->
        close(state)
    end
  end

  defp refreshed(state, :valid),
    do: %{state | table_menu: %{state.table_menu | dirty: false, progress_dirty: false}}

  defp refreshed(state, {_kind, block, view}, opts \\ []) do
    menu = %{state.table_menu | block: block, view: view, dirty: false, progress_dirty: false}
    CreativeInventory.resync_inventory(%{state | table_menu: menu}, opts)
  end

  @doc "A click in the open menu (`container_click` for its window)."
  def click(%{player: %{game_mode: %{current: :spectator}}} = state, _click),
    do: CreativeInventory.resync_inventory(state)

  def click(%{table_menu: %{kind: :merchant}} = state, click),
    do: Valimc.Player.Merchant.click(state, click)

  def click(state, click) do
    if table_player_valid?(state) and current_owner?(state, state.table_menu),
      do: menu_click(state, click),
      else: close(state)
  end

  defp menu_click(%{table_menu: %{kind: :table}} = state, click) do
    case Click.plan(
           Menu.table(),
           nil,
           state.inventory,
           click.action,
           click.slot,
           click.button
         ) do
      {:ok, nil, inventory, []} ->
        send_packets(state, [
          Valimc.Menus.Packets.table_inventory(state.table_menu.id, inventory),
          Packets.cursor(inventory.carried)
        ])

        %{state | inventory: inventory}

      {:ok, nil, inventory, stacks} ->
        thrown(state, inventory, stacks, click)

      {:error, _} ->
        CreativeInventory.resync_inventory(state)
    end
  end

  defp menu_click(%{table_menu: menu} = state, click) do
    actor = %{
      mode: state.player.game_mode.current,
      eye: Valimc.Living.Interaction.eye(state.player),
      position: {state.player.x, state.player.y, state.player.z},
      health: state.player.living.health.value,
      expires: System.monotonic_time(:millisecond) + 250
    }

    # Throws drop where the player stands, from its own group (VMC-077i3).
    click = Map.merge(click, %{inventory: state.inventory, drops: Items.local?(state)})

    case Region.container_click(
           menu.owner,
           state.connection,
           menu.view_ref,
           menu.position,
           actor,
           click
         ) do
      {:ok, inventory, view, learned, drops} ->
        state = learn(%{state | inventory: inventory}, learned)

        state =
          case Items.drop(state, inventory, drops) do
            {:ok, state} -> state
            :error -> state
          end

        refreshed(state, {menu.kind, menu.block, view}, drag: :keep)

      {:error, _} ->
        refresh(state, :refresh)
    end
  end

  # A furnace's earned output teaches its recipes.
  defp learn(state, []), do: state

  defp learn(state, recipes) do
    case Valimc.Player.Progression.learn(state.player.progression, recipes) do
      {:ok, progression} ->
        learned = MapSet.difference(progression.recipes, state.player.progression.recipes)

        if MapSet.size(learned) > 0,
          do: send_packets(state, [Valimc.Blocks.CookingRecipeBook.packet(learned, false, true)])

        put_in(state.player.progression, progression)

      _ ->
        state
    end
  end

  @doc """
  An inventory or table click that throws `stacks` out, `inventory` being
  what is left; a crafting gesture that keeps its result repeats.
  """
  def thrown(state, inventory, stacks, click, repeats \\ @repeats) do
    original = Inventory.crafting_result(state.inventory)

    case Items.drop(state, inventory, stacks) do
      {:ok, state} ->
        remaining = Inventory.crafting_result(inventory)

        repeating =
          click.slot == 0 and
            {click.action, click.button} in [{:throw, 1}, {:quick_move, 0}, {:quick_move, 1}]

        if repeating and repeats > 0 and original != nil and remaining != nil and
             ItemStack.same_item?(remaining, original),
           do: repeat(state, click, repeats - 1),
           else: CreativeInventory.resync_inventory(state)

      :error ->
        CreativeInventory.resync_inventory(state)
    end
  end

  defp repeat(state, click, repeats) do
    menu = if state.table_menu, do: Menu.table(), else: Menu.inventory()

    case Click.plan(menu, nil, state.inventory, click.action, 0, click.button) do
      {:ok, nil, inventory, []} ->
        CreativeInventory.resync_inventory(%{state | inventory: inventory})

      {:ok, nil, inventory, stacks} ->
        thrown(state, inventory, stacks, click, repeats)

      {:error, _} ->
        CreativeInventory.resync_inventory(state)
    end
  end

  @doc "Release the open container view at its owner."
  def retire_container_view(%{table_menu: %{kind: kind} = menu} = state)
      when kind in @containers,
      do:
        Enum.each(Map.get(menu.view, :owners, [menu.owner]), fn owner ->
          Region.unsubscribe_container(owner, state.connection, menu.view_ref)
        end)

  def retire_container_view(_), do: :ok

  @doc """
  Close the open menu (it tells the client) and return the cursor and grid to
  the inventory; what does not fit drops. Without a menu nothing happens.
  """
  def close(%{table_menu: nil} = state), do: state

  def close(state) do
    send_packets(state, [Packets.packet("container_close", Wire.varint(state.table_menu.id))])
    closed(state)
  end

  @doc "The client closed its own inventory screen or the menu (after `close/1`)."
  def closed(state) do
    state = Valimc.Player.Merchant.stop(state)
    retire_container_view(state)
    return(%{state | table_menu: nil})
  end

  defp return(%{life_stage: stage} = state) when stage != :alive, do: state

  defp return(state) do
    case Inventory.close(state.inventory) do
      {:ok, inventory, []} ->
        CreativeInventory.resync_inventory(%{state | inventory: inventory})

      {:ok, inventory, stacks} ->
        case Items.drop(state, inventory, stacks) do
          {:ok, state} -> CreativeInventory.resync_inventory(state)
          :error -> CreativeInventory.resync_inventory(state)
        end

      {:error, _} ->
        send_packets(state, [
          Packets.chat("Menu return exceeds inventory limits; inventory restored")
        ])

        CreativeInventory.resync_inventory(state)
    end
  end
end
