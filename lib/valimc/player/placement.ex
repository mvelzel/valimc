defmodule Valimc.Player.Placement do
  @moduledoc "Block placement inside the connection: creative and survival placement queues, previews and corrections (VMC-069)."

  alias Valimc.Protocol.{
    Data,
    Packets,
    UseItemOn
  }

  alias Valimc.Session.Jobs
  alias Valimc.Player.Menus
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Transfers
  alias Valimc.Player.Mining
  alias Valimc.Player.ItemUse

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{Inventory, PlayerInput, PlayerPlacementQuery, PlayerStore, World}
  alias Valimc.Player.State, as: PlayerState

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def place_block(state, payload) do
    case UseItemOn.decode(payload) do
      {:ok, request} ->
        cond do
          state.table_menu != nil or inventory_pending(state) or
              not Mining.inside_border?(request.position) ->
            Menus.acknowledge_table_use(state, request)

          state.life_stage == :alive and PlayerInput.loaded?(state.player.input) and
            not state.teleport_pending and state.save_ref == nil and
            MapSet.member?(
              near_chunks(state.player),
              World.chunk_key(elem(request.position, 0), elem(request.position, 2))
            ) and
            Mining.reachable?(state, request.position) and
              Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) ->
            Menus.request_table(state, :open, request.position, request)

          true ->
            execute_placement(state, request)
        end

      {:error, _} ->
        reject(state, "Malformed block interaction")
    end
  end

  @doc false
  def capture_placement(state, request) do
    stack = Inventory.held(state.inventory, request.hand)

    command =
      cond do
        # Flint and steel and fire charges set fire or open portals (VMC-026b2).
        Valimc.Portal.Items.item?(stack) ->
          %{
            kind: :ignite,
            request: Map.put(request, :yaw, state.player.yaw),
            item: stack.item_id,
            stack: stack,
            slot: if(request.hand == :off, do: 45, else: 36 + state.inventory.selected),
            mode: state.player.game_mode.current,
            body: placement_body(state, request),
            expires: System.monotonic_time(:millisecond) + 250
          }

        Valimc.Physics.Placement.supported_stack?(stack) ->
          %{
            request: Map.put(request, :yaw, state.player.yaw),
            item: stack.item_id,
            stack: stack,
            slot: if(request.hand == :off, do: 45, else: 36 + state.inventory.selected),
            mode: state.player.game_mode.current,
            body: placement_body(state, request),
            expires:
              System.monotonic_time(:millisecond) +
                Valimc.Txn.Permits.window(250, state.player.uuid)
          }

        stack != nil and Valimc.Physics.Placement.supported_item?(stack.item_id) ->
          %{kind: :correction, mode: :correction, request: request, body: nil}

        # Creative placement of a block item without modelled placement: its
        # block's default state beside the clicked face, through the same fenced
        # owner commit as modelled placement (VMC-077a).
        block = creative_block(state, stack) ->
          %{
            request: Map.merge(request, %{yaw: state.player.yaw, pitch: state.player.pitch}),
            item: {:block, block},
            stack: stack,
            slot: if(request.hand == :off, do: 45, else: 36 + state.inventory.selected),
            mode: :creative,
            body: placement_body(state, request),
            expires:
              System.monotonic_time(:millisecond) +
                Valimc.Txn.Permits.window(250, state.player.uuid)
          }

        # Anything else changes no block: vanilla still sends both blocks back.
        true ->
          %{kind: :correction, mode: :correction, request: request, body: nil}
      end

    %{stack: stack, command: command}
  end

  # Container variants without an owned record are corrected, never written as empty shells.
  defp creative_block(state, stack) do
    with %{item_id: item} <- stack,
         :creative <- state.player.game_mode.current,
         block when is_integer(block) <- Data.item_block(item),
         false <- Valimc.Physics.BlockEntities.unsupported?(block),
         do: block,
         else: (_ -> nil)
  end

  def execute_placement(state, request, captured \\ nil) do
    captured = captured || capture_placement(state, request)

    cond do
      not Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) or
          not Mining.reachable?(state, request.position) ->
        send_packets(state, [Packets.ack(request.sequence)])
        CreativeInventory.resync_inventory(state)

      true ->
        if state.placement_queued >= 16,
          do: reject(state, "Too many pending block interactions")

        state =
          if captured.command[:kind] == :correction,
            do: CreativeInventory.resync_inventory(state),
            else: state

        drain_placements(%{
          state
          | placement_queue: :queue.in(captured.command, state.placement_queue),
            placement_queued: state.placement_queued + 1
        })
    end
  end

  def placement_body(state, request) do
    mode = state.player.game_mode.current

    if state.life_stage == :alive and state.player.living.health.value > 0 and
         ((mode == :creative and state.inventory.infinite_materials) or
            (mode == :survival and not state.inventory.infinite_materials)) and
         PlayerInput.loaded?(state.player.input) and
         not state.teleport_pending and not inventory_pending(state) and
         Mining.reachable?(state, request.position) and
         Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) do
      %{boxes: [body(state.player) | peer_bodies(state)], chunks: near_chunks(state.player)}
    end
  end

  # The chunks around the player: a reachable block is in one of them, and its
  # client has them once it confirmed its position.
  defp near_chunks(%{x: x, z: z}) do
    {cx, cz} = World.chunk_key(x, z)
    MapSet.new(for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz})
  end

  # Placement is obstructed by every nearby living player that is not a
  # spectator (vanilla's `isUnobstructed`), the placing player included.
  defp peer_bodies(state) do
    for pid <- Valimc.Players.around(state.player),
        pid != state.connection,
        {:ok, peer} <- [Valimc.Players.get(pid)],
        peer.game_mode.current != :spectator and peer.living.health.value > 0,
        do: body(peer)
  end

  defp body(player) do
    {:ok, geometry} =
      Valimc.Physics.PlayerPose.geometry(player.pose, {player.x, player.y, player.z})

    geometry.box
  end

  @doc false
  def drain_placements(%{jobs: jobs} = state) when is_map_key(jobs.active, :placement),
    do: state

  def drain_placements(state)
      when state.recovery != nil or state.save_ref != nil or state.use_save != nil,
      do: state

  def drain_placements(state) do
    case :queue.out(state.placement_queue) do
      {:empty, _} ->
        state

      {{:value, command}, queue} ->
        state = %{state | placement_queue: queue, placement_queued: state.placement_queued - 1}

        start =
          if command.mode == :survival,
            do: &PlayerPlacementQuery.start_survival/5,
            else: &PlayerPlacementQuery.start_creative/5

        started =
          case command[:kind] do
            :destroy ->
              PlayerPlacementQuery.start_destroy(
                command.request.position,
                command.eye,
                command.expires,
                state.connection
              )

            :correction ->
              PlayerPlacementQuery.start_correction(command.request, nil, state.connection)

            :ignite ->
              Valimc.Portal.Items.start(command, state.connection)

            _ ->
              start.(
                command.item,
                command.request,
                command.body,
                command.expires,
                state.connection
              )
          end

        case started do
          {:ok, task} ->
            {jobs, _job} =
              Jobs.track(state.jobs, :placement, task, timeout: 750, data: %{command: command})

            %{state | jobs: jobs}

          {:error, _} ->
            reject(state, "Block interaction capacity reached; please reconnect")
        end
    end
  end

  def prepare_survival_placement(state, command, reservation) do
    if command.body != nil and state.life_stage == :alive and state.player.living.health.value > 0 and
         state.player.game_mode.current == :survival and not state.inventory.infinite_materials and
         not state.teleport_pending and not inventory_pending(state) and state.save_ref == nil and
         System.monotonic_time(:millisecond) < command.expires and
         command.slot ==
           if(command.request.hand == :off, do: 45, else: 36 + state.inventory.selected) and
         Inventory.get(state.inventory, command.slot) == command.stack do
      after_stack =
        if command.stack.count == 1,
          do: nil,
          else: %{command.stack | count: command.stack.count - 1}

      slots =
        if after_stack,
          do: Map.put(state.inventory.slots, command.slot, after_stack),
          else: Map.delete(state.inventory.slots, command.slot)

      inventory =
        %{state.inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()

      intent =
        reservation
        |> Map.take([:key, :permit, :expected])
        |> Map.merge(%{
          kind: :placement,
          slot: command.slot,
          before: command.stack,
          after: after_stack,
          request: Map.delete(command.request, :yaw),
          edits: %{reservation.candidate.position => reservation.candidate.state}
        })

      ref = make_ref()

      recovery = %{
        Transfers.new_recovery(state, :play, :prepare, nil)
        | ref: ref,
          plan: %{
            key: reservation.key,
            records: [],
            inventory: inventory,
            intent: intent,
            reservation: reservation
          }
      }

      PlayerStore.prepare_placement(
        state.player_store,
        state.store_fence,
        PlayerState.capture(state.player, state.inventory),
        intent,
        ref
      )

      state |> Mining.cancel_mining() |> ItemUse.stop_item_use() |> Map.put(:recovery, recovery)
    else
      correct_placement(state, command.request, reservation)
    end
  end

  @doc false
  def correct_placement(state, request, reservation) do
    case PlayerPlacementQuery.start_correction(request, reservation, state.connection) do
      {:ok, task} ->
        command = %{mode: :correction, body: nil, request: request}

        {jobs, _job} =
          Jobs.track(state.jobs, :placement, task, timeout: 750, data: %{command: command})

        %{state | jobs: jobs}

      {:error, _} ->
        reject(state, "Block correction capacity reached; please reconnect")
    end
  end
end
