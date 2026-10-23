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
  portals light them in a task (`Valimc.World.Portal.Items`), since a portal's
  frame may span sections.
  """
  alias Valimc.Data.Grid
  alias Valimc.Physics.{CollisionContext, Kernel}
  alias Valimc.Blocks.Placement, as: Rules
  alias Valimc.Protocol.{Packets, UseItemOn}
  alias Valimc.Player.Jobs
  alias Valimc.Player.{CreativeInventory, ItemUse, Menus, Mining}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Input
  alias Valimc.World
  alias Valimc.World.{BlockBatch, Region}

  import Bitwise, only: [<<<: 2]
  import Valimc.Protocol.Codec, only: [send_packets: 2, reject: 2]

  @placement %CollisionContext{kind: :entity, placement: true}
  @bone_meal Valimc.Protocol.Data.item("bone_meal")

  def place_block(state, payload) do
    case UseItemOn.decode(payload) do
      {:ok, request} ->
        cond do
          state.table_menu != nil or not Mining.inside_border?(request.position) ->
            Menus.acknowledge_table_use(state, request)

          state.life_stage == :alive and Input.loaded?(state.player.input) and
            not state.teleport_pending and
            MapSet.member?(
              near_chunks(state.player),
              Grid.chunk_key(elem(request.position, 0), elem(request.position, 2))
            ) and
            Mining.reachable?(state, request.position) and
              Valimc.Living.Interaction.valid_hit?(request.position, request.cursor) ->
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
      not Valimc.Living.Interaction.valid_hit?(request.position, request.cursor) or
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
      Valimc.World.Portal.Items.item?(stack) ->
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

      # Hoes, shovels and axes transform blocks (VMC-039a), unless the main
      # hand's use gives way to a shield's (`playerHasBlockingItemUseIntent`).
      tool = Valimc.Blocks.Transformers.tool(stack) ->
        %{
          kind: :transform,
          tool: tool,
          request: request,
          stack: stack,
          slot: slot,
          mode: state.player.game_mode.current,
          body:
            unless(
              request.hand == :main and
                Valimc.Living.Weapons.blocks_attacks(Inventory.held(state.inventory, :off)) !=
                  nil and not Valimc.Player.Input.pressed?(state.player.input, :shift),
              do: body(state, request)
            )
        }

      # Bone meal grows what takes it (VMC-039a).
      stack != nil and stack.item_id == @bone_meal ->
        %{
          kind: :bone_meal,
          request: request,
          stack: stack,
          slot: slot,
          mode: state.player.game_mode.current,
          body: body(state, request)
        }

      placeable?(state, request, stack) ->
        %{
          kind: :place,
          request:
            Map.merge(request, %{
              yaw: state.player.yaw,
              pitch: state.player.pitch,
              secondary: Valimc.Player.Input.pressed?(state.player.input, :shift)
            }),
          item: stack.item_id,
          stack: stack,
          slot: slot,
          mode: state.player.game_mode.current,
          body: body(state, request)
        }

      # Anything else changes no block: vanilla still sends both blocks back.
      true ->
        %{kind: :correction, request: request}
    end
  end

  @doc """
  A lily pad or frogspawn used from `hand` (`PlaceOnWaterBlockItem.use`): the
  player's ray through water sources finds the source looked at, and the item
  places as a click on the cell above it, without the checks a client's click
  takes (vanilla's ray stays within reach).
  """
  def place_on_water(state, hand, sequence) do
    case Valimc.Player.Buckets.aim(state.player, :empty) do
      %{miss: false, position: {x, y, z}, face: face, location: {lx, ly, lz}} ->
        request = %{
          hand: hand,
          position: {x, y + 1, z},
          face: face,
          cursor: {lx - x, ly - (y + 1), lz - z},
          inside: false,
          sequence: sequence,
          on_water: true
        }

        if Jobs.active?(state.jobs, :placement),
          do: CreativeInventory.resync_inventory(state),
          else: run(state, command(state, request))

      _ ->
        CreativeInventory.resync_inventory(state)
    end
  end

  # Operator blocks place only for creative operators (`GameMasterBlockItem`);
  # lily pads and frogspawn only by use (`place_on_water/3`).
  defp placeable?(state, request, stack) do
    Rules.placeable_stack?(stack) and
      Rules.on_water?(stack.item_id) == Map.get(request, :on_water, false) and
      (not Rules.operator?(stack.item_id) or
         (state.player.game_mode.current == :creative and
            Valimc.Admin.Permissions.level(state.player) >= 2))
  end

  # The bodies a placement must not enter, when the player may place at all.
  defp body(state, request) do
    mode = state.player.game_mode.current

    if state.life_stage == :alive and state.player.living.health.value > 0 and
         ((mode == :creative and state.inventory.infinite_materials) or
            (mode == :survival and not state.inventory.infinite_materials)) and
         Input.loaded?(state.player.input) and not state.teleport_pending and
         (Map.get(request, :on_water, false) or
            (Mining.reachable?(state, request.position) and
               Valimc.Living.Interaction.valid_hit?(request.position, request.cursor))) do
      %{boxes: [box(state.player) | peer_boxes(state)], chunks: near_chunks(state.player)}
    end
  end

  # The chunks around the player: a reachable block is in one of them, and its
  # client has them once it confirmed its position.
  defp near_chunks(%{x: x, z: z}) do
    {cx, cz} = Grid.chunk_key(x, z)
    MapSet.new(for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz})
  end

  # Placement is obstructed by every nearby living player that is not a
  # spectator (vanilla's `isUnobstructed`), the placing player included.
  defp peer_boxes(state) do
    for pid <- Valimc.Player.PlayerList.around(state.player),
        pid != state.connection,
        {:ok, peer} <- [Valimc.Player.PlayerList.get(pid)],
        peer.game_mode.current != :spectator and peer.living.health.value > 0,
        do: box(peer)
  end

  defp box(player) do
    {:ok, geometry} =
      Valimc.Data.PlayerPose.geometry(player.pose, {player.x, player.y, player.z})

    geometry.box
  end

  defp run(state, %{kind: :correction, request: request}) do
    state = CreativeInventory.resync_inventory(state)
    acknowledge(state, request)
  end

  defp run(state, %{kind: :ignite} = command) do
    case Valimc.World.Portal.Items.start(command, state.connection) do
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

  # `BoneMealItem.useOn` on the clicked block, in its owner: used up in
  # survival when the block took it; what the generator grows (a sapling's
  # tree, a grass block's flowers) grows in a task.
  defp run(state, %{kind: :bone_meal, request: request} = command) do
    used =
      with %{} <- command.body,
           {:ok, owner} <- owner(request.position),
           corals = Valimc.World.Growth.corals?(state.player.dimension, Rules.adjacent(request)),
           {:ok, result} when result > 0 <-
             Region.bucket(owner, {:bone_meal, request.position, request.face, corals}) do
        if result == 2,
          do: Valimc.World.Growth.start(state.player.dimension, request.position)

        true
      else
        _ -> false
      end

    state =
      if used and command.mode == :survival,
        do: use_up(state, command),
        else: CreativeInventory.resync_inventory(state)

    acknowledge(state, request)
  end

  # `BlockTransformer.transformBlock` on the clicked block, in its owner:
  # the entry's sound to the others near it and its particles, and the
  # tool's wear in survival.
  defp run(state, %{kind: :transform, request: request} = command) do
    applied =
      with %{} <- command.body,
           {:ok, owner} <- owner(request.position),
           {:ok, index} when index > 0 <-
             Region.bucket(owner, {:transform, request.position, command.tool, request.face}) do
        Valimc.Blocks.Transformers.entry(command.tool, index - 1)
      else
        _ -> nil
      end

    state =
      case applied do
        nil ->
          CreativeInventory.resync_inventory(state)

        entry ->
          transformed(state, request.position, entry)
          if command.mode == :survival, do: wear(state, command, entry), else: state
      end

    acknowledge(state, request)
  end

  defp transformed(state, {x, y, z} = position, entry) do
    key = Grid.section(state.player.dimension, Grid.chunk_key(x, z))
    at = {x + 0.5, y + 0.5, z + 0.5}
    packet = Valimc.World.Sounds.packet(entry.sound, :block, at, :rand.uniform(1 <<< 62))
    World.publish(key, {:sound, at, 16.0, packet, state.connection})

    if entry.particle != 0,
      do: World.publish(key, {:level_events, [{position, entry.particle, 0}], state.connection})
  end

  # A tool wears by the entry's damage (`hurtAndBreak`); a stackable item is
  # used up instead, when the entry consumes it.
  defp wear(state, command, entry) do
    inventory = state.inventory
    stack = Inventory.get(inventory, command.slot)

    if stack != command.stack do
      CreativeInventory.resync_inventory(state)
    else
      {next, broken} =
        if Valimc.Protocol.ItemStack.max_stack_size(stack) > 1,
          do: {used(stack, not entry.consume), nil},
          else: Valimc.Living.Durability.hurt_and_break(stack, entry.damage, false)

      {:ok, inventory} = Inventory.creative(inventory, command.slot, next)
      state = %{state | inventory: inventory} |> CreativeInventory.resync_inventory()

      if broken do
        packet = Packets.item_break(state.player.entity_id, command.request.hand)
        send_packets(state, [packet])
        Valimc.Player.Movement.broadcast_player_packet(state, packet)
      end

      Valimc.Player.ItemUse.publish_equipment(state)
    end
  end

  @doc "The portal item's use ended (`Valimc.World.Portal.Items`): it wears and is acknowledged."
  def ignited(state, command, outcome, after_ack) do
    state = Valimc.World.Portal.Items.used(state, command, outcome)
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

  # A survival placement uses up one of the held stack, as the client
  # predicted; a solid bucket leaves an empty bucket (`SolidBucketItem`).
  defp use_up(state, command) do
    stack = command.stack

    if Inventory.get(state.inventory, command.slot) == stack do
      left =
        if Rules.bucket?(stack.item_id) and not state.inventory.infinite_materials,
          do: Valimc.Protocol.ItemStack.new("bucket"),
          else: used(stack, state.inventory.infinite_materials)

      slots =
        case left do
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
         true <- Valimc.Living.Interaction.within_block?(:creative, eye, position) do
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
      |> Enum.group_by(fn {x, _, z} ->
        Grid.region_key(Grid.chunk_key(x, z))
      end)
      |> Enum.flat_map(fn {key, positions} ->
        with {:ok, owner} <-
               World.existing_owner(Grid.section(state.player.dimension, key, :section)),
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
    do:
      World.existing_owner(
        Grid.section(
          Valimc.World.Dimension.current(),
          Grid.chunk_key(x, z)
        )
      )

  defp deadline, do: System.monotonic_time(:millisecond) + 250

  defp admitted?(plan, body) do
    {x, _, z} = plan.candidate.position

    MapSet.member?(body.chunks, Grid.chunk_key(x, z)) and
      not Kernel.obstructs?(plan.candidate.state, plan.candidate.position, @placement, body.boxes)
  end

  # The click's target (the clicked block, when the held item replaces it,
  # else the cell beside the clicked face) and what vanilla writes there,
  # which the owner's placement rules decide from the cells around it
  # (VMC-029d): the placed block and a door's, bed's or tall plant's other
  # half. The two cells may lie in different sections of the group
  # (VMC-077z); the writes go to the target's, all of them in it. Cells in
  # two groups are refused.
  defp plan(item, request) do
    adjacent = Rules.adjacent(request)

    with {:ok, sections} <- observe([request.position, adjacent]),
         blocks = sections |> Map.values() |> Enum.map(& &1.blocks) |> Enum.reduce(&Map.merge/2),
         {:ok, %{position: target, values: values}} <-
           Rules.target(item, blocks[request.position], request),
         key = section_key(target),
         %{owner: owner, fence: fence} = sections[key],
         {:ok, writes} <- Region.placement(owner, item, values, target),
         :ok <- in_section(writes, key),
         candidate = main_write(writes, target),
         :ok <- single_chest(candidate),
         {:ok, batch} <- BlockBatch.prepare(Map.new(writes)) do
      {:ok, %{owner: owner, revision: fence, candidate: candidate, batch: batch}}
    end
  end

  # A door's or bed's other half across a section line is not placed yet.
  defp in_section(writes, key) do
    if Enum.all?(writes, fn {position, _} -> section_key(position) == key end),
      do: :ok,
      else: {:error, :cross_section_placement}
  end

  # The placed block: the one at the target, or the only one written (a
  # scaffolding placed along a column).
  defp main_write(writes, target) do
    {position, state} = List.keyfind(writes, target, 0) || hd(writes)
    %{position: position, state: state}
  end

  # `positions` read at their sections' owners, by section key, when one
  # group holds them all.
  defp observe(positions) do
    owners =
      positions
      |> Enum.uniq()
      |> Enum.group_by(&section_key/1)
      |> Enum.reduce_while(%{}, fn {key, positions}, acc ->
        case owner(hd(positions)) do
          {:ok, owner} -> {:cont, Map.put(acc, key, {owner, positions})}
          error -> {:halt, error}
        end
      end)

    with %{} <- owners,
         [_] <- owners |> Map.values() |> Enum.uniq_by(fn {{pid, _}, _} -> pid end) do
      Enum.reduce_while(owners, {:ok, %{}}, fn {key, {owner, positions}}, {:ok, acc} ->
        case Region.observe_blocks(owner, positions) do
          {:ok, observed} ->
            {:cont,
             {:ok,
              Map.put(acc, key, %{owner: owner, fence: observed.fence, blocks: observed.blocks})}}

          error ->
            {:halt, error}
        end
      end)
    else
      [_, _ | _] -> {:error, :cross_owner_placement}
      error -> error
    end
  end

  defp section_key({x, _, z}), do: Grid.region_key(Grid.chunk_key(x, z))

  # A chest that would join its neighbour into a double chest is refused
  # until double chests exist (VMC-032b).
  defp single_chest(%{state: state}) do
    if Valimc.Blocks.Chest.ordinary?(state) and not Valimc.Blocks.Chest.single?(state),
      do: {:error, :unsupported_double_chest},
      else: :ok
  end
end
