defmodule Valimc.Player.Mining do
  @moduledoc "Block breaking inside the connection: reach, creative breaks and survival mining jobs, commits and corrections (VMC-069)."

  alias Valimc.Protocol.{
    Data,
    ItemTypes,
    Packets,
    Wire
  }

  alias Valimc.Session.Jobs
  alias Valimc.Player.Movement
  alias Valimc.Player.ItemUse

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    Inventory,
    PlayerInput,
    PlayerMining,
    PlayerMiningAttempt,
    PlayerMiningQuery,
    PlayerSnapshot,
    PlayerStore,
    World
  }

  @basic_mining Enum.map(~w(stone dirt grass_block cobblestone oak_planks glass), &Data.block/1)
  @slab_blocks Data.tags()["minecraft:block"]["minecraft:slabs"] |> MapSet.new()

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def reachable?(state, {x, y, z}) do
    p = state.player

    World.Chunk.valid_y?(y) and
      Valimc.PlayerInteraction.within_block?(
        p.game_mode.current,
        Valimc.PlayerInteraction.eye(p),
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
        Valimc.Player.Transfers.drop_selected(
          state,
          action == ItemTypes.action_id("drop_all_items")
        )

      action == ItemTypes.action_id("swap_item_with_offhand") and inventory_pending(state) ->
        Valimc.Player.CreativeInventory.resync_inventory(state)

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

  def survival_mining_action(state, action, position) do
    cond do
      action == ItemTypes.action_id("abort_destroy_block") ->
        cancel_mining(state)

      action == ItemTypes.action_id("start_destroy_block") ->
        state = state |> cancel_mining() |> ItemUse.stop_item_use()

        if mining_allowed?(state, position) do
          mining = %{
            position: position,
            started: state.simulation_clock.tick,
            requested_at: System.monotonic_time(:millisecond),
            stopped: false,
            attempt: nil,
            reservation: nil,
            needs_check: true,
            renew_at: 0
          }

          tick_mining(%{state | mining: mining})
        else
          correct_mining(state, position)
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
      PlayerInput.loaded?(state.player.input) and not state.teleport_pending and
      not inventory_pending(state) and reachable?(state, position) and
      inside_border?(position) and
      Valimc.MiningTools.can_destroy?(Inventory.held(state.inventory, :main), false)
  end

  @doc "Vanilla's `mayInteract`: blocks outside the world border cannot be broken or used."
  def inside_border?(position),
    do: Valimc.World.Border.interactable?(Valimc.World.Clock.border_physics(), position)

  def mining_changed(%{mining: nil} = state), do: state
  def mining_changed(state), do: %{state | mining: %{state.mining | needs_check: true}}

  def tick_mining(%{mining: nil} = state), do: state

  def tick_mining(%{recovery: %{plan: %{intent: %{kind: :pickup}}}} = state), do: state

  def tick_mining(state) do
    mining = state.mining
    now = System.monotonic_time(:millisecond)

    cond do
      not mining_allowed?(state, mining.position) ->
        state |> cancel_mining() |> correct_mining(mining.position)

      Jobs.active?(state.jobs, :mining) ->
        state

      mining.reservation == nil and now - mining.requested_at >= 500 ->
        cancel_mining(state)

      mining.reservation == nil ->
        mining_job(
          state,
          :reserve,
          PlayerMiningQuery.reserve(state.player.dimension, mining.position),
          mining.position
        )

      World.existing_owner(
        World.section(state.player.dimension, mining.reservation.key, :section)
      ) !=
          {:ok, mining.reservation.owner} ->
        state |> cancel_mining() |> correct_mining(mining.position)

      mining.needs_check or now >= mining.renew_at ->
        mining_job(state, :renew, PlayerMiningQuery.renew(mining.reservation), mining.position)

      state.pose_checked != Movement.pose_signature(state) ->
        state

      true ->
        block = Map.fetch!(mining.reservation.expected, mining.position)

        {:ok, rate} =
          PlayerMining.rate(
            state.inventory,
            block,
            state.mining_water,
            state.player.motion.on_ground
          )

        {attempt, events} =
          if mining.attempt == nil do
            {:ok, attempt, events} =
              PlayerMiningAttempt.start(mining.position, block, rate, mining.started)

            {attempt, events}
          else
            {:ok, attempt, events} =
              PlayerMiningAttempt.tick(mining.attempt, block, rate, state.simulation_clock.tick)

            {attempt, events}
          end

        {attempt, events} =
          if mining.stopped and attempt.phase == :active do
            {:ok, attempt, next} =
              PlayerMiningAttempt.stop(attempt, block, rate, state.simulation_clock.tick)

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
  end

  def mining_job(state, stage, {:ok, task}, position) do
    {jobs, _job} =
      Jobs.track(state.jobs, :mining, task,
        timeout: 250,
        data: %{
          stage: stage,
          position: position,
          generation: state.pose_generation,
          deadline: System.monotonic_time(:millisecond) + 250
        }
      )

    %{state | jobs: jobs}
  end

  def mining_job(state, _, {:error, _}, _), do: state

  def mining_result(
        %{mining: %{position: position} = mining} = state,
        %{stage: :reserve, position: position} = job,
        {:ok, reservation}
      ) do
    block = Map.fetch!(reservation.expected, position)

    mining = %{
      mining
      | reservation: reservation,
        needs_check: job.generation != state.pose_generation,
        renew_at: System.monotonic_time(:millisecond) + 5000
    }

    state = %{state | mining: mining}

    supported =
      block in @basic_mining or
        Valimc.Block.block_entity(block) != nil or
        Valimc.MiningLoot.ordinary_mining?(block) or
        Valimc.RandomMiningLoot.supported?(block) or
        MapSet.member?(@slab_blocks, Valimc.MiningTools.block_id(block))

    if supported and mining_allowed?(state, position) do
      tick_mining(state)
    else
      send_packets(state, [Packets.block(position, block)])
      cancel_mining(state)
    end
  end

  def mining_result(%{mining: mining} = state, %{stage: :renew} = job, {:ok, expected})
      when mining != nil do
    if expected == mining.reservation.expected do
      mining = %{
        mining
        | needs_check: job.generation != state.pose_generation,
          renew_at: System.monotonic_time(:millisecond) + 5000
      }

      tick_mining(%{state | mining: mining})
    else
      state |> cancel_mining() |> correct_mining(job.position)
    end
  end

  # An imported block entity's data follows its block: the client dropped the
  # block entity when it predicted the break (VMC-021e1).
  def mining_result(state, %{stage: :correct} = job, {:ok, owner, block, update}) do
    key =
      World.section(
        state.player.dimension,
        World.chunk_key(elem(job.position, 0), elem(job.position, 2))
      )

    if job.generation == state.pose_generation and World.existing_owner(key) == {:ok, owner} and
         reachable?(state, job.position),
       do: send_packets(state, [Packets.block(job.position, block) | List.wrap(update)])

    state
  end

  def mining_result(state, %{stage: :correct}, _), do: state
  def mining_result(state, job, _), do: state |> cancel_mining() |> correct_mining(job.position)

  @doc false
  def cancel_mining(state) do
    {_job, jobs} = Jobs.cancel(state.jobs, :mining)
    state = %{state | jobs: jobs}

    if state.mining do
      mining = state.mining

      Movement.broadcast_player_packet(
        state,
        Packets.block_destruction(state.player.entity_id, mining.position, -1)
      )

      if mining.reservation, do: PlayerMiningQuery.release(mining.reservation)
    end

    %{state | mining: nil}
  end

  def correct_mining(state, position) do
    if not Jobs.active?(state.jobs, :mining) and reachable?(state, position),
      do:
        mining_job(
          state,
          :correct,
          PlayerMiningQuery.observe(state.player.dimension, position),
          position
        ),
      else: state
  end

  def correct_block_recovery(state, recovery) do
    intent = if recovery.intent, do: recovery.intent[:outbox], else: recovery.plan[:intent]

    case {recovery.mode, intent} do
      {:play, %{kind: :mining}} ->
        correct_mining(state, intent.target)

      {:play, %{kind: :placement}} ->
        Valimc.Player.Placement.correct_placement(
          state,
          intent.request,
          recovery.plan.reservation
        )

      _ ->
        state
    end
  end

  def commit_mining(%{save_ref: ref} = state) when ref != nil, do: state

  def commit_mining(state) do
    mining = state.mining
    reservation = mining.reservation
    block = Map.fetch!(reservation.expected, mining.position)
    before = Inventory.held(state.inventory, :main)

    {:ok, drops} =
      Valimc.MiningLoot.drops(
        block,
        before,
        PlayerMining.harvest?(state.inventory, block)
      )

    {after_tool, _broken} = Valimc.Durability.mine(before, block, false)
    {x, y, z} = mining.position

    records =
      Enum.map(drops, fn stack ->
        %{uuid: :crypto.strong_rand_bytes(16), x: x + 0.5, y: y + 0.5, z: z + 0.5, stack: stack}
      end)

    slot = 36 + state.inventory.selected

    slots =
      if after_tool,
        do: Map.put(state.inventory.slots, slot, after_tool),
        else: Map.delete(state.inventory.slots, slot)

    inventory =
      %{state.inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()

    intent =
      reservation
      |> Map.take([:key, :permit, :expected])
      |> Map.merge(%{
        kind: :mining,
        target: mining.position,
        slot: slot,
        before: before,
        after: after_tool,
        records: records
      })

    ref = make_ref()

    recovery = %{
      Valimc.Player.Transfers.new_recovery(:play, :prepare, nil)
      | ref: ref,
        plan: %{key: reservation.key, records: records, inventory: inventory, intent: intent}
    }

    PlayerStore.prepare_mining(
      state.player_store,
      state.store_fence,
      PlayerSnapshot.capture(state.player, state.inventory),
      intent,
      ref
    )

    # This intent now resolves through the durable lane; attempt cancellation must not release its permit.
    %{state | mining: nil, recovery: recovery}
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
      if state.placement_queued >= 16, do: reject(state, "Too many pending block interactions")

      command = %{
        kind: :destroy,
        mode: :creative,
        request: %{position: position, sequence: sequence},
        eye: Valimc.PlayerInteraction.eye(state.player),
        body: %{},
        expires:
          System.monotonic_time(:millisecond) + Valimc.Txn.Permits.window(250, state.player.uuid)
      }

      Valimc.Player.Placement.drain_placements(%{
        state
        | placement_queue: :queue.in(command, state.placement_queue),
          placement_queued: state.placement_queued + 1
      })
    else
      send_packets(state, [Packets.ack(sequence)])
      state
    end
  end
end
