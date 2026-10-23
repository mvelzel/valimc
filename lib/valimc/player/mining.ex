defmodule Valimc.Player.Mining do
  @moduledoc """
  Block breaking (VMC-069, VMC-077i3): reach, creative breaks and survival
  mining. The block's owner is the player's own group: a survival attempt
  reads the block it mines from it, rereads it when blocks change, and on
  completion breaks it as `Valimc.Blocks.Breaking` plans (VMC-029e: every
  block, its drops and experience) in one plain call
  (`Region.mine_block/4`), wearing the tool in the same callback.
  """
  alias Valimc.Data.Grid
  alias Valimc.Protocol.{ItemTypes, Packets, Wire}
  alias Valimc.Player.{CreativeInventory, Items, ItemUse, Movement}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Input, MiningSpeed, MiningAttempt}
  alias Valimc.World
  alias Valimc.World.Region

  import Valimc.Protocol.Codec, only: [send_packets: 2, reject: 2]

  def reachable?(state, {x, y, z}) do
    p = state.player

    World.Chunk.valid_y?(y) and
      Valimc.Living.Interaction.within_block?(
        p.game_mode.current,
        Valimc.Living.Interaction.eye(p),
        {x, y, z}
      )
  end

  def break_block(state, payload) do
    {action, payload} = Wire.take_varint(payload)
    {position, <<face, payload::binary>>} = Wire.take_position(payload)
    {sequence, <<>>} = Wire.take_varint(payload)
    if face not in 0..5, do: reject(state, "Invalid action face")

    cond do
      action == ItemTypes.action_id("release_use_item") ->
        ItemUse.stop_item_use(state)

      state.player.game_mode.current == :spectator and
          action in [
            ItemTypes.action_id("drop_item"),
            ItemTypes.action_id("drop_all_items"),
            ItemTypes.action_id("swap_item_with_offhand")
          ] ->
        state

      action in [ItemTypes.action_id("drop_item"), ItemTypes.action_id("drop_all_items")] ->
        drop_selected(state, action == ItemTypes.action_id("drop_all_items"))

      action == ItemTypes.action_id("swap_item_with_offhand") ->
        state = ItemUse.stop_item_use(state)
        inventory = Inventory.swap_hands(state.inventory)

        send_packets(state, [
          Packets.container_slot(
            inventory.state_id,
            36 + inventory.selected,
            Inventory.held(inventory, :main)
          ),
          Packets.container_slot(inventory.state_id, 45, Inventory.held(inventory, :off))
        ])

        %{state | inventory: inventory}

      true ->
        break_block_action(state, action, position, sequence)
    end
  end

  # Q and ctrl+Q: one or all of the held stack, thrown from the eyes.
  defp drop_selected(state, all) do
    with {:ok, inventory, stack} when stack != nil <-
           Inventory.drop_selected(state.inventory, all),
         {:ok, state} <- Items.drop(state, inventory, [stack]) do
      CreativeInventory.resync_inventory(state)
    else
      _ -> CreativeInventory.resync_inventory(state)
    end
  end

  def survival_mining_action(state, action, position) do
    cond do
      action == ItemTypes.action_id("abort_destroy_block") ->
        cancel_mining(state)

      action == ItemTypes.action_id("start_destroy_block") ->
        state = state |> cancel_mining() |> ItemUse.stop_item_use()

        with true <- mining_allowed?(state, position),
             {:ok, owner, block} <- observe(state, position),
             # Vanilla starts no attempt on air.
             false <- Valimc.Data.BlockFacts.flag?(block, :air) do
          mining = %{
            position: position,
            owner: owner,
            block: block,
            started: state.simulation_clock.tick,
            stopped: false,
            attempt: nil,
            needs_check: false
          }

          tick_mining(%{state | mining: mining})
        else
          _ -> correct_mining(state, position)
        end

      action == ItemTypes.action_id("stop_destroy_block") ->
        case state.mining do
          %{position: ^position} = mining ->
            tick_mining(%{state | mining: %{mining | stopped: true}})

          _ ->
            state |> cancel_mining() |> correct_mining(position)
        end

      true ->
        state
    end
  end

  def mining_allowed?(state, position) do
    state.phase == :play and state.life_stage == :alive and
      state.player.game_mode.current == :survival and state.player.living.health.value > 0 and
      Input.loaded?(state.player.input) and not state.teleport_pending and
      reachable?(state, position) and inside_border?(position) and
      Valimc.Blocks.MiningTools.can_destroy?(Inventory.held(state.inventory, :main), false)
  end

  @doc "Vanilla's `mayInteract`: blocks outside the world border cannot be broken or used."
  def inside_border?(position),
    do: Valimc.World.Border.interactable?(Valimc.World.Clock.border_physics(), position)

  def mining_changed(%{mining: nil} = state), do: state
  def mining_changed(state), do: %{state | mining: %{state.mining | needs_check: true}}

  def tick_mining(%{mining: nil} = state), do: state

  def tick_mining(state) do
    mining = state.mining

    cond do
      not mining_allowed?(state, mining.position) ->
        state |> cancel_mining() |> correct_mining(mining.position)

      mining.needs_check ->
        case observe(state, mining.position) do
          {:ok, owner, block} when owner == mining.owner and block == mining.block ->
            tick_mining(%{state | mining: %{mining | needs_check: false}})

          _ ->
            state |> cancel_mining() |> correct_mining(mining.position)
        end

      state.pose_checked != Movement.pose_signature(state) ->
        state

      true ->
        progress(state, mining)
    end
  end

  defp progress(state, mining) do
    block = mining.block

    {:ok, rate} =
      MiningSpeed.rate(state.inventory, block, state.mining_water, state.player.motion.on_ground)

    {:ok, attempt, events} =
      if mining.attempt == nil,
        do: MiningAttempt.start(mining.position, block, rate, mining.started),
        else: MiningAttempt.tick(mining.attempt, block, rate, state.simulation_clock.tick)

    {attempt, events} =
      if mining.stopped and attempt.phase == :active do
        {:ok, attempt, next} =
          MiningAttempt.stop(attempt, block, rate, state.simulation_clock.tick)

        {attempt, events ++ next}
      else
        {attempt, events}
      end

    state = %{state | mining: %{mining | attempt: attempt}}

    for {:crack, stage} <- events,
        do:
          Movement.broadcast_player_packet(
            state,
            Packets.block_destruction(state.player.entity_id, mining.position, stage)
          )

    if attempt.phase == :ready, do: commit_mining(state), else: state
  end

  # What a break reads around the block: the blocks above and below (from
  # the same owner, which holds whole columns) and whether water evaporates.
  defp around(owner, {x, y, z}, dimension) do
    cells = for dy <- [1, -1], World.Chunk.valid_y?(y + dy), do: {x, y + dy, z}

    blocks =
      case Region.observe_blocks(owner, cells) do
        {:ok, observed} -> observed.blocks
        _ -> %{}
      end

    %{
      above: blocks[{x, y + 1, z}],
      below: blocks[{x, y - 1, z}],
      evaporates: Valimc.Blocks.Fluids.evaporates?(Valimc.World.Dimension.facts(dimension).type)
    }
  end

  # The block at `position` from its owner, the player's own group.
  defp observe(state, {x, _, z} = position) do
    with {:ok, owner} <-
           World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))),
         {:ok, observed} <- Region.observe_blocks(owner, [position]),
         do: {:ok, owner, Map.fetch!(observed.blocks, position)}
  end

  @doc false
  def cancel_mining(%{mining: nil} = state), do: state

  def cancel_mining(state) do
    Movement.broadcast_player_packet(
      state,
      Packets.block_destruction(state.player.entity_id, state.mining.position, -1)
    )

    %{state | mining: nil}
  end

  @doc """
  Send the block at `position` back to the client (with its preserved block
  entity data, which the client dropped when it predicted the break).
  """
  def correct_mining(state, {x, _, z} = position) do
    with true <- reachable?(state, position),
         {:ok, owner} <-
           World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))),
         {:ok, observed} <- Region.observe_blocks(owner, [position]),
         {:ok, update} <- Region.block_entity_update(owner, position) do
      send_packets(state, [Packets.block(position, observed.blocks[position]) | List.wrap(update)])
    end

    state
  end

  # The attempt completed: the block breaks as planned with its drops and
  # experience, and the tool wears.
  defp commit_mining(state) do
    %{position: {x, y, z} = position, block: block, owner: owner} = state.mining
    before = Inventory.held(state.inventory, :main)
    around = around(owner, position, state.player.dimension)

    plan =
      Valimc.Blocks.Breaking.plan(
        block,
        position,
        before,
        MiningSpeed.harvest?(state.inventory, block),
        around
      )

    {after_tool, _broken} = Valimc.Living.Durability.mine(before, block, false)

    records =
      Enum.map(plan.drops, &Valimc.Entity.ItemDrop.pop(position, &1)) ++
        Valimc.Entity.ExperienceOrbs.drop({x + 0.5, y + 0.5, z + 0.5}, plan.experience)

    state = %{state | mining: nil}

    case Region.mine_block(owner, position, plan.writes, records) do
      :ok ->
        slot = 36 + state.inventory.selected

        slots =
          if after_tool,
            do: Map.put(state.inventory.slots, slot, after_tool),
            else: Map.delete(state.inventory.slots, slot)

        inventory =
          %{state.inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()

        # A harvest (`Block.playerDestroy`) costs food.
        food =
          if plan.harvest,
            do: Valimc.Player.Food.exhaust(state.player.food, 0.005),
            else: state.player.food

        state = %{state | inventory: inventory, player: %{state.player | food: food}}
        CreativeInventory.resync_inventory(state)

      {:error, _} ->
        correct_mining(state, position)
    end
  end

  def break_block_action(
        %{player: %{game_mode: %{current: :survival}}} = state,
        action,
        position,
        sequence
      ) do
    send_packets(state, [Packets.ack(sequence)])
    survival_mining_action(state, action, position)
  end

  def break_block_action(state, action, position, sequence) do
    if action in [
         ItemTypes.action_id("start_destroy_block"),
         ItemTypes.action_id("stop_destroy_block")
       ] and
         state.player.game_mode.current == :creative and state.life_stage == :alive and
         reachable?(state, position) and inside_border?(position) and not state.teleport_pending do
      Valimc.Player.Placement.destroy(
        state,
        position,
        sequence,
        Valimc.Living.Interaction.eye(state.player)
      )
    else
      send_packets(state, [Packets.ack(sequence)])
      state
    end
  end
end
