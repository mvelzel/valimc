defmodule Valimc.Player.Menus do
  @moduledoc "Table, chest and furnace menus inside the connection: admission, opening, clicks, container actions, closing and crafting repeats (VMC-069)."

  alias Valimc.Protocol.{
    Data,
    ItemStack,
    Packets,
    Wire
  }

  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Transfers
  alias Valimc.Player.Mining
  alias Valimc.Player.ItemUse

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    Inventory,
    Menu,
    MenuClick,
    PlayerContainerQuery,
    PlayerInput,
    PlayerStore,
    World
  }

  alias Valimc.Player.State, as: PlayerState

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def table_signature(state) do
    {state.player.game_mode.current, PlayerInput.pressed?(state.player.input, :shift),
     Map.take(state.inventory, [
       :slots,
       :carried,
       :selected,
       :infinite_materials,
       :table_inputs,
       :drag
     ])}
  end

  def selection_pending?(
        %{table_job: %{kind: :open}, player: %{game_mode: %{current: :creative}}} = state
      ),
      do: inventory_pending(%{state | table_job: nil})

  def selection_pending?(state), do: inventory_pending(state)

  def menu_signature(%{table_menu: %{kind: kind}} = state) when kind in [:chest, :cooking],
    do: container_signature(state)

  def menu_signature(state), do: table_signature(state)

  @doc false
  def request_table(state, kind, {x, _, z} = position, command) do
    key = World.section(state.player.dimension, World.chunk_key(x, z))

    expires =
      System.monotonic_time(:millisecond) + Valimc.Txn.Permits.window(250, state.player.uuid)

    grant = %{
      kind: if(kind == :progress, do: :refresh, else: kind),
      mode: state.player.game_mode.current,
      eye: Valimc.PlayerInteraction.eye(state.player),
      expires: expires,
      hand: if(kind == :open, do: command.hand, else: :main),
      secondary: PlayerInput.pressed?(state.player.input, :shift),
      main: Inventory.held(state.inventory, :main) != nil,
      off: Inventory.held(state.inventory, :off) != nil
    }

    grant =
      if state.table_menu do
        Map.merge(grant, %{
          menu: state.table_menu.kind,
          view_ref: state.table_menu[:view_ref],
          revision:
            if(state.table_menu.kind in [:chest, :cooking] and kind not in [:refresh, :progress],
              do: state.table_menu.view.revision
            )
        })
      else
        grant
      end

    case World.existing_owner(key) do
      {:ok, {pid, _} = owner} ->
        if kind != :open and state.table_menu.owner != owner do
          begin_table_close(state)
        else
          ref = make_ref()
          monitor = Process.monitor(pid)
          timer = Process.send_after(state.connection, {:table_deadline, ref}, 300)

          job = %{
            ref: ref,
            monitor: monitor,
            timer: timer,
            owner: owner,
            key: key,
            kind: kind,
            position: position,
            grant: grant,
            command: command,
            placement:
              if(kind == :open, do: Valimc.Player.Placement.capture_placement(state, command)),
            signature: menu_signature(state)
          }

          state = %{state | table_job: job}

          case Valimc.World.Region.request_table(owner, state.connection, ref, position, grant) do
            :ok -> state
            _ -> fail_table_query(state)
          end
        end

      _ ->
        if kind == :open,
          do: acknowledge_table_use(state, command),
          else: begin_table_close(state)
    end
  end

  def cancel_table_query(%{table_job: nil} = state), do: state

  def cancel_table_query(state) do
    Process.cancel_timer(state.table_job.timer)
    Process.demonitor(state.table_job.monitor, [:flush])

    if task = state.table_job[:task] do
      Process.exit(task.pid, :kill)
      Process.demonitor(task.ref, [:flush])
    end

    if state.table_job.kind == :open, do: send(self(), :drain)
    %{state | table_job: nil}
  end

  @doc false
  def fail_table_query(%{table_job: %{kind: :open, command: command}} = state),
    do: state |> cancel_table_query() |> acknowledge_table_use(command)

  def fail_table_query(state), do: state |> cancel_table_query() |> begin_table_close()

  def acknowledge_table_use(state, request) do
    send_packets(state, [Packets.ack(request.sequence)])
    CreativeInventory.resync_inventory(state)
  end

  def open_table_menu(state, position, owner, sequence) do
    id = rem(state.table_counter, 127) + 1

    inventory =
      %{Inventory.cancel_drag(state.inventory) | table_inputs: Tuple.duplicate(nil, 9)}
      |> Inventory.advance()

    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()

    send_packets(state, [
      Packets.ack(sequence),
      Packets.open_table(id),
      Packets.table_inventory(id, inventory),
      Packets.cursor(inventory.carried)
    ])

    %{
      state
      | inventory: inventory,
        table_menu: %{kind: :table, id: id, position: position, owner: owner},
        table_counter: id
    }
  end

  def open_container_menu(state, kind, position, owner, block, view, sequence) do
    id = rem(state.table_counter, 127) + 1
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()
    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()

    {open, content, properties} =
      case kind do
        :chest ->
          {Packets.open_chest(id, view.rows),
           Packets.chest_inventory(id, view.rows, view.slots, inventory), []}

        :cooking ->
          {Packets.open_cooking(id, view.kind),
           Packets.cooking_inventory(id, view.cooking, inventory),
           Packets.cooking_properties(id, view.cooking)}
      end

    send_packets(
      state,
      [
        Packets.ack(sequence),
        open,
        content,
        Packets.cursor(inventory.carried)
      ] ++ properties
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
          monitor: Process.monitor(elem(owner, 0)),
          subscribed: false,
          dirty: false,
          progress_dirty: false,
          opener: kind == :chest and state.player.game_mode.current != :spectator
        },
        table_counter: id
    }

    request_table(state, :subscribe, position, nil)
  end

  def table_player_valid?(%{table_menu: nil}), do: false

  def table_player_valid?(state) do
    menu = state.table_menu

    block =
      if menu.kind == :table, do: Data.item_block(Data.item("crafting_table")), else: menu.block

    valid =
      Valimc.MenuAccess.valid_view?(
        menu.kind,
        block,
        state.player.game_mode.current,
        Valimc.PlayerInteraction.eye(state.player),
        menu.position
      )

    state.life_stage == :alive and not state.teleport_pending and
      PlayerInput.loaded?(state.player.input) and valid
  end

  def check_table_menu(%{table_menu: nil} = state), do: state

  def check_table_menu(%{table_menu: %{kind: kind} = menu} = state)
      when kind in [:chest, :cooking] do
    key =
      World.section(
        state.player.dimension,
        World.chunk_key(elem(menu.position, 0), elem(menu.position, 2))
      )

    opener = kind == :chest and state.player.game_mode.current != :spectator

    cond do
      not table_player_valid?(state) or World.existing_owner(key) != {:ok, menu.owner} ->
        begin_table_close(state)

      inventory_pending(state) or state.save_ref != nil ->
        state

      menu.opener != opener ->
        Valimc.World.Region.unsubscribe_container(menu.owner, state.connection, menu.view_ref)

        menu = %{
          menu
          | view_ref: make_ref(),
            opener: opener,
            subscribed: false
        }

        request_table(%{state | table_menu: menu}, :subscribe, menu.position, nil)

      not menu.subscribed ->
        request_table(state, :subscribe, menu.position, nil)

      menu.dirty ->
        request_table(state, :refresh, menu.position, nil)

      state.table_queued > 0 ->
        drain_table_clicks(state)

      menu.progress_dirty ->
        request_table(state, :progress, menu.position, nil)

      true ->
        state
    end
  end

  def check_table_menu(state) do
    cond do
      not table_player_valid?(state) -> begin_table_close(state)
      inventory_pending(state) or state.save_ref != nil -> state
      state.table_queued > 0 -> drain_table_clicks(state)
      true -> request_table(state, :check, state.table_menu.position, nil)
    end
  end

  @doc false
  def drain_table_clicks(state) when inventory_pending(state) or state.save_ref != nil, do: state
  def drain_table_clicks(%{table_menu: nil} = state), do: state

  def drain_table_clicks(state) do
    case :queue.out(state.table_queue) do
      {:empty, _} ->
        state

      {{:value, click}, queue} ->
        state = %{state | table_queue: queue, table_queued: state.table_queued - 1}
        request_table(state, :click, state.table_menu.position, click)
    end
  end

  def apply_table_click(%{player: %{game_mode: %{current: :spectator}}} = state, _),
    do: CreativeInventory.resync_inventory(state)

  def apply_table_click(state, click) do
    case MenuClick.plan(
           Menu.table(),
           nil,
           state.inventory,
           click.action,
           click.slot,
           click.button
         ) do
      {:ok, nil, inventory, []} ->
        send_packets(state, [
          Packets.table_inventory(state.table_menu.id, inventory),
          Packets.cursor(inventory.carried)
        ])

        %{state | inventory: inventory}

      {:ok, nil, inventory, [_ | _] = stacks} ->
        start_click_transfer(state, inventory, stacks, click)

      {:error, _} ->
        CreativeInventory.resync_inventory(state)
    end
  end

  def apply_menu_click(%{table_menu: %{kind: kind}} = state, click)
      when kind in [:chest, :cooking],
      do: begin_container_action(state, click)

  def apply_menu_click(state, click), do: apply_table_click(state, click)

  def begin_container_action(%{player: %{game_mode: %{current: :spectator}}} = state, _),
    do: CreativeInventory.resync_inventory(state)

  def begin_container_action(state, click) do
    menu = state.table_menu

    proposal =
      Map.merge(container_request_view(menu.view), %{
        inventory: state.inventory,
        action: click.action,
        slot: click.slot,
        button: click.button
      })

    with {:ok, slots, inventory} <-
           Valimc.World.ContainerRequest.plan(proposal),
         false <-
           slots == proposal.slots and
             %{inventory | state_id: state.inventory.state_id} == state.inventory do
      proposal =
        if menu.kind == :cooking and menu.view.recipes != %{} and
             elem(slots, 2) != elem(proposal.slots, 2) do
          Map.put(proposal, :award, %{
            position: {state.player.x, state.player.y, state.player.z},
            recipes: Enum.sort(Map.keys(menu.view.recipes))
          })
        else
          proposal
        end

      ref = make_ref()

      job = %{
        kind: :container,
        stage: :candidate,
        ref: ref,
        owner: menu.owner,
        menu: menu.id,
        monitor: Process.monitor(elem(menu.owner, 0)),
        timer: Process.send_after(state.connection, {:table_deadline, ref}, 300),
        signature: container_signature(state),
        task: nil,
        intent: nil,
        actor: nil
      }

      {x, _, z} = menu.position

      intent = %{
        kind: :container,
        key: World.region_key(World.chunk_key(x, z)),
        request:
          Map.merge(proposal, %{
            permit: <<0::128>>,
            position: menu.position,
            revision: menu.view.revision
          })
      }

      PlayerStore.container_candidate(
        state.player_store,
        state.store_fence,
        PlayerState.capture(state.player, state.inventory),
        intent,
        ref
      )

      %{state | table_job: job}
    else
      _ -> CreativeInventory.resync_inventory(state)
    end
  end

  def container_request_view(%{rows: rows, slots: slots}), do: %{rows: rows, slots: slots}

  def container_request_view(%{kind: kind, cooking: cooking}),
    do: %{kind: kind, slots: cooking.slots}

  def container_action_current?(state, job) do
    match?(
      %{kind: kind, id: id, owner: owner}
      when kind in [:chest, :cooking] and id == job.menu and owner == job.owner,
      state.table_menu
    ) and container_signature(state) == job.signature and
      table_player_valid?(state) and state.player.living.health.value > 0 and
      World.existing_owner(
        World.section(
          state.player.dimension,
          World.chunk_key(
            elem(state.table_menu.position, 0),
            elem(state.table_menu.position, 2)
          )
        )
      ) == {:ok, job.owner}
  end

  def container_signature(state) do
    {mode, _secondary, items} = table_signature(state)
    {mode, items}
  end

  def admit_container_action(state, intent) do
    actor = %{
      uuid: state.player.uuid,
      mode: state.player.game_mode.current,
      position: {state.player.x, state.player.y, state.player.z},
      eye: Valimc.PlayerInteraction.eye(state.player),
      health: state.player.living.health.value,
      expires:
        System.monotonic_time(:millisecond) + Valimc.Txn.Permits.window(250, state.player.uuid)
    }

    case PlayerContainerQuery.start(state.table_job.owner, intent.request, actor) do
      {:ok, task} ->
        %{
          state
          | table_job: %{
              state.table_job
              | stage: :admit,
                task: task,
                intent: intent,
                actor: actor
            }
        }

      _ ->
        fail_chest_action(state)
    end
  end

  def fail_chest_action(state) do
    state = cancel_table_query(state)

    if table_player_valid?(state),
      do: request_table(state, :refresh, state.table_menu.position, nil),
      else: begin_table_close(state)
  end

  def prepare_chest_action(state, intent) do
    state = cancel_table_query(state)
    ref = make_ref()
    snapshot = PlayerState.capture(state.player, state.inventory)

    recovery = %{
      Transfers.new_recovery(state, :play, :prepare, nil)
      | ref: ref,
        plan: %{
          key: intent.key,
          records: [],
          inventory: state.inventory,
          intent: intent,
          snapshot: snapshot
        }
    }

    PlayerStore.prepare_container(state.player_store, state.store_fence, snapshot, intent, ref)
    CreativeInventory.resync_inventory(%{state | recovery: recovery})
  end

  def retire_container_view(%{table_menu: %{kind: kind} = menu} = state)
      when kind in [:chest, :cooking] do
    Valimc.World.Region.unsubscribe_container(menu.owner, state.connection, menu.view_ref)
    Process.demonitor(menu.monitor, [:flush])
  end

  def retire_container_view(_), do: :ok

  @doc false
  def begin_table_close(%{table_menu: nil} = state), do: continue_table_close(state)

  def begin_table_close(state) do
    send_packets(state, [Packets.packet("container_close", Wire.varint(state.table_menu.id))])
    retire_container_view(state)
    state = cancel_table_query(state)

    continue_table_close(%{
      state
      | table_menu: nil,
        table_closing: true,
        crafting_repeat: nil,
        table_queue: :queue.new(),
        table_queued: 0
    })
  end

  @doc false
  def continue_table_close(%{table_closing: false} = state), do: state

  def continue_table_close(%{life_stage: stage} = state) when stage != :alive,
    do: %{state | table_closing: false}

  def continue_table_close(state) when inventory_busy(state) or state.save_ref != nil, do: state

  def continue_table_close(state) do
    case Inventory.close(state.inventory) do
      {:ok, inventory, []} ->
        CreativeInventory.resync_inventory(%{state | inventory: inventory, table_closing: false})

      {:ok, inventory, [_ | _] = stacks} ->
        Transfers.prepare_inventory_transfer(state, inventory, stacks)

      {:error, _} ->
        if state.inventory.table_inputs do
          reject(state, "Menu cleanup could not be planned; reconnect to recover")
        else
          send_packets(state, [
            Packets.chat("Menu return exceeds inventory limits; inventory restored")
          ])

          CreativeInventory.resync_inventory(%{state | table_closing: false})
        end
    end
  end

  @doc false
  def start_click_transfer(state, inventory, stacks, click) do
    crafting = if click.slot == 0, do: {click.action, click.button}
    next = Transfers.start_inventory_transfer(state, inventory, stacks, crafting)

    original = Inventory.crafting_result(state.inventory)
    remaining = Inventory.crafting_result(inventory)
    repeats = crafting == {:throw, 1} or crafting in [{:quick_move, 0}, {:quick_move, 1}]

    if repeats and original != nil and remaining != nil and
         ItemStack.same_item?(remaining, original) and next.recovery != nil do
      %{
        next
        | crafting_repeat: %{click: click, output: original}
      }
    else
      next
    end
  end

  def continue_crafting_repeat(%{crafting_repeat: nil} = state), do: state

  def continue_crafting_repeat(%{life_stage: stage} = state) when stage != :alive,
    do: %{state | crafting_repeat: nil}

  def continue_crafting_repeat(%{table_closing: true} = state),
    do: %{state | crafting_repeat: nil}

  def continue_crafting_repeat(state) when inventory_busy(state) or state.save_ref != nil,
    do: state

  def continue_crafting_repeat(state) do
    repeat = state.crafting_repeat
    state = %{state | crafting_repeat: nil}
    result = Inventory.crafting_result(state.inventory)

    cond do
      result == nil or not ItemStack.same_item?(result, repeat.output) ->
        CreativeInventory.resync_inventory(state)

      repeat.click.container == 0 and state.table_menu == nil ->
        case MenuClick.plan(
               Menu.inventory(),
               nil,
               state.inventory,
               repeat.click.action,
               0,
               repeat.click.button
             ) do
          {:ok, nil, inventory, [_ | _] = stacks} ->
            start_click_transfer(state, inventory, stacks, repeat.click)

          {:ok, nil, inventory, []} ->
            CreativeInventory.resync_inventory(%{state | inventory: inventory})

          {:error, _} ->
            CreativeInventory.resync_inventory(state)
        end

      state.table_menu != nil and repeat.click.container == state.table_menu.id ->
        request_table(state, :click, state.table_menu.position, repeat.click)

      true ->
        CreativeInventory.resync_inventory(state)
    end
  end
end
