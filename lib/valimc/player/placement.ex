defmodule Valimc.Player.Placement do
  @moduledoc """
  Block placement (VMC-069, VMC-077i3): a `use_item_on` that does not open a
  menu places the held block, as vanilla's `BlockItem.useOn`. The block's
  owner is the player's own group, so the plan (the clicked neighbourhood, the
  candidate state, survival and obstruction) and the placement are plain calls
  to it, and a survival player's item is used up in the same callback. The
  clicked and adjacent blocks are then resent before the acknowledgement, as
  the client predicted them.

  Creative players also destroy blocks at once (`destroy/4`). Items that make
  portals light them in a task (`Valimc.Portal.Items`), since a portal's
  frame may span sections.
  """
  alias Valimc.Physics.{CollisionContext, Kernel}
  alias Valimc.Physics.Placement, as: Rules
  alias Valimc.Protocol.{Data, Packets, UseItemOn}
  alias Valimc.Session.Jobs
  alias Valimc.Player.{CreativeInventory, ItemUse, Menus, Mining}
  alias Valimc.{Inventory, PlayerInput, World}
  alias Valimc.World.{BlockBatch, Region}

  import Valimc.Net.Codec, only: [send_packets: 2, reject: 2]

  @placement %CollisionContext{kind: :entity, placement: true}

  def place_block(state, payload) do
    case UseItemOn.decode(payload) do
      {:ok, request} ->
        cond do
          state.table_menu != nil or not Mining.inside_border?(request.position) ->
            Menus.acknowledge_table_use(state, request)

          state.life_stage == :alive and PlayerInput.loaded?(state.player.input) and
            not state.teleport_pending and
            MapSet.member?(
              near_chunks(state.player),
              World.chunk_key(elem(request.position, 0), elem(request.position, 2))
            ) and
            Mining.reachable?(state, request.position) and
              Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) ->
            Menus.use_block(state, request.position, request)

          true ->
            execute_placement(state, request)
        end

      {:error, _} ->
        reject(state, "Malformed block interaction")
    end
  end

  @doc "Place the held item against `request`'s block (no menu opened there)."
  def execute_placement(state, request) do
    cond do
      not Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) or
          not Mining.reachable?(state, request.position) ->
        send_packets(state, [Packets.ack(request.sequence)])
        CreativeInventory.resync_inventory(state)

      Jobs.active?(state.jobs, :placement) ->
        Menus.acknowledge_table_use(state, request)

      true ->
        run(state, command(state, request))
    end
  end

  # What the held stack does against the clicked block.
  defp command(state, request) do
    stack = Inventory.held(state.inventory, request.hand)
    slot = if request.hand == :off, do: 45, else: 36 + state.inventory.selected

    cond do
      # Flint and steel and fire charges set fire or open portals (VMC-026b2).
      Valimc.Portal.Items.item?(stack) ->
        %{
          kind: :ignite,
          request: Map.put(request, :yaw, state.player.yaw),
          item: stack.item_id,
          stack: stack,
          slot: slot,
          mode: state.player.game_mode.current,
          body: body(state, request),
          expires: System.monotonic_time(:millisecond) + 250
        }

      Rules.supported_stack?(stack) ->
        %{
          kind: :place,
          request: Map.put(request, :yaw, state.player.yaw),
          item: stack.item_id,
          stack: stack,
          slot: slot,
          mode: state.player.game_mode.current,
          body: body(state, request)
        }

      stack != nil and Rules.supported_item?(stack.item_id) ->
        %{kind: :correction, request: request}

      # Creative placement of a block item without modelled placement: its
      # block's default state beside the clicked face (VMC-077a).
      block = creative_block(state, stack) ->
        %{
          kind: :place,
          request: Map.merge(request, %{yaw: state.player.yaw, pitch: state.player.pitch}),
          item: {:block, block},
          stack: stack,
          slot: slot,
          mode: :creative,
          body: body(state, request)
        }

      # Anything else changes no block: vanilla still sends both blocks back.
      true ->
        %{kind: :correction, request: request}
    end
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

  # The bodies a placement must not enter, when the player may place at all.
  defp body(state, request) do
    mode = state.player.game_mode.current

    if state.life_stage == :alive and state.player.living.health.value > 0 and
         ((mode == :creative and state.inventory.infinite_materials) or
            (mode == :survival and not state.inventory.infinite_materials)) and
         PlayerInput.loaded?(state.player.input) and not state.teleport_pending and
         Mining.reachable?(state, request.position) and
         Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) do
      %{boxes: [box(state.player) | peer_boxes(state)], chunks: near_chunks(state.player)}
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
  defp peer_boxes(state) do
    for pid <- Valimc.Players.around(state.player),
        pid != state.connection,
        {:ok, peer} <- [Valimc.Players.get(pid)],
        peer.game_mode.current != :spectator and peer.living.health.value > 0,
        do: box(peer)
  end

  defp box(player) do
    {:ok, geometry} =
      Valimc.Physics.PlayerPose.geometry(player.pose, {player.x, player.y, player.z})

    geometry.box
  end

  defp run(state, %{kind: :correction, request: request}) do
    state = CreativeInventory.resync_inventory(state)
    acknowledge(state, request)
  end

  defp run(state, %{kind: :ignite} = command) do
    case Valimc.Portal.Items.start(command, state.connection) do
      {:ok, task} ->
        {jobs, _job} =
          Jobs.track(state.jobs, :placement, task, timeout: 750, data: %{command: command})

        %{state | jobs: jobs}

      {:error, _} ->
        Menus.acknowledge_table_use(state, command.request)
    end
  end

  defp run(state, %{kind: :place} = command) do
    placed =
      with %{} = body <- command.body,
           {:ok, plan} <- plan(command.item, command.request),
           true <- admitted?(plan, body),
           {:ok, _} <- Region.place_block(plan.owner, plan.revision, plan.batch, deadline()),
           do: true,
           else: (_ -> false)

    state =
      cond do
        placed and command.mode == :survival -> use_up(state, command)
        command.body == nil or not placed -> CreativeInventory.resync_inventory(state)
        true -> state
      end

    acknowledge(state, command.request)
  end

  @doc "The portal item's use ended (`Valimc.Portal.Items`): it wears and is acknowledged."
  def ignited(state, command, outcome, after_ack) do
    state = Valimc.Portal.Items.used(state, command, outcome)
    send_packets(state, [Packets.ack(command.request.sequence) | after_ack])
    state
  end

  @doc """
  What is left of the held `stack` after it placed a block: one fewer, nil
  when that was the last; creative players (`infinite`) keep it whole.
  """
  def used(stack, true), do: stack
  def used(%{count: 1}, false), do: nil
  def used(stack, false), do: %{stack | count: stack.count - 1}

  # A survival placement uses up one of the held stack, as the client predicted.
  defp use_up(state, command) do
    stack = command.stack

    if Inventory.get(state.inventory, command.slot) == stack do
      slots =
        case used(stack, state.inventory.infinite_materials) do
          nil -> Map.delete(state.inventory.slots, command.slot)
          left -> Map.put(state.inventory.slots, command.slot, left)
        end

      inventory =
        %{state.inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()

      %{state | inventory: inventory}
      |> Mining.cancel_mining()
      |> ItemUse.stop_item_use()
      |> CreativeInventory.resync_inventory()
    else
      CreativeInventory.resync_inventory(state)
    end
  end

  @doc """
  A creative player's break at `position` (`start_destroy_block`): the
  block goes at once, then both are resent before the acknowledgement.
  """
  def destroy(state, position, sequence, eye) do
    with {:ok, owner} <- owner(position),
         {:ok, observed} <- Region.observe_blocks(owner, [position]),
         true <- Valimc.PlayerInteraction.within_block?(:creative, eye, position) do
      Region.destroy_block(owner, observed.fence, position, deadline())
    end

    acknowledge(state, %{position: position, sequence: sequence}, [position])
  end

  # The clicked and adjacent blocks go back to the client (with preserved
  # block entity data after the acknowledgement, which the client otherwise
  # drops while its prediction is pending).
  defp acknowledge(state, request, positions \\ nil) do
    positions = positions || Enum.uniq([request.position, Rules.adjacent(request)])

    updates =
      positions
      |> Enum.group_by(fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end)
      |> Enum.flat_map(fn {key, positions} ->
        with {:ok, owner} <-
               World.existing_owner(World.section(state.player.dimension, key, :section)),
             :ok <- Region.correct_blocks(owner, positions, state.connection) do
          for position <- positions,
              {:ok, update} <- [Region.block_entity_update(owner, position)],
              update != nil,
              do: update
        else
          _ -> []
        end
      end)

    send_packets(state, [Packets.ack(request.sequence) | updates])
    state
  end

  defp owner({x, _, z}),
    do: World.existing_owner(World.section(Valimc.Dimension.current(), World.chunk_key(x, z)))

  defp deadline, do: System.monotonic_time(:millisecond) + 250

  defp admitted?(plan, body) do
    {x, _, z} = plan.candidate.position

    MapSet.member?(body.chunks, World.chunk_key(x, z)) and
      not Kernel.obstructs?(plan.candidate.state, plan.candidate.position, @placement, body.boxes)
  end

  # The clicked neighbourhood at one owner, the candidate state that survives
  # there, and a single chest only beside no other chest.
  defp plan(item, request) do
    positions = Enum.uniq([request.position, Rules.adjacent(request)])
    groups = Enum.group_by(positions, fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end)

    with [{key, positions}] <- Map.to_list(groups),
         {:ok, owner} <- owner(hd(positions)),
         {:ok, observed} <- Region.observe_blocks(owner, positions),
         {:ok, candidate} <-
           candidate(
             item,
             observed.blocks[request.position],
             observed.blocks[Rules.adjacent(request)],
             request
           ),
         {:ok, candidate} <- surviving(owner, candidate),
         {:ok, batch} <- BlockBatch.prepare(%{candidate.position => candidate.state}),
         :ok <- isolated_chest(owner, key, candidate, observed.fence) do
      {:ok, %{owner: owner, revision: observed.fence, candidate: candidate, batch: batch}}
    else
      groups when is_list(groups) -> {:error, :cross_owner_placement}
      error -> error
    end
  end

  # A creative block item without modelled placement (VMC-077a): its block on
  # a replaceable block beside the clicked face, in the first of its candidate
  # states that can survive there (`Rules.creative_states/4`).
  defp candidate({:block, block}, clicked, adjacent, request) do
    with true <- Rules.replaceable?(adjacent) || {:error, :occupied},
         [_ | _] = states <- Rules.creative_states(block, clicked, adjacent, request) do
      {:ok, %{position: Rules.adjacent(request), states: states, replace_clicked: false}}
    else
      [] -> {:error, :cannot_survive}
      error -> error
    end
  end

  defp candidate(item, clicked, adjacent, request),
    do: Rules.candidate(item, clicked, adjacent, request)

  defp surviving(owner, %{states: states} = candidate) do
    with {:ok, state} <- Region.placement_state(owner, candidate.position, states),
         do: {:ok, candidate |> Map.delete(:states) |> Map.put(:state, state)}
  end

  defp surviving(_owner, candidate), do: {:ok, candidate}

  defp isolated_chest(owner, key, candidate, revision) do
    if Valimc.Block.Chest.single?(candidate.state) do
      neighbors = Valimc.ChestPlacement.neighbors(candidate.position)

      if Enum.all?(neighbors, fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) == key end) do
        with {:ok, observed} <- Region.observe_blocks(owner, neighbors, revision),
             false <-
               Enum.any?(observed.blocks, fn {_, state} -> Valimc.Block.Chest.ordinary?(state) end),
             do: :ok,
             else: (
               true -> {:error, :adjacent_chest}
               error -> error
             )
      else
        {:error, :cross_owner_chest}
      end
    else
      :ok
    end
  end
end
