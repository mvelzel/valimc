defmodule Valimc.Player.Sleep do
  @moduledoc """
  A player sleeping in a bed (VMC-040a), in its session, as vanilla's
  `ServerPlayer.startSleepInBed`, `Player.tick` and `stopSleepInBed` run it.

  A player lies down in a bed it can reach (3 blocks around either half, 2
  up or down) with room above both halves, when no monster that keeps
  players from resting stands within 8 blocks of the bed and 5 above or
  below (unless it is in creative), and when the dimension's bed rule lets
  it sleep now. Wherever the rule lets the bed set the spawn, the bed
  becomes the player's respawn point first (`Valimc.Player.RespawnPoint`),
  even when it cannot sleep. Lying down moves it onto the bed, marks both
  halves occupied, sets the sleeping pose and the bed in its entity data,
  and restarts its time since rest; its session then ignores its moves
  (one more than a block away is sent back).

  Each tick a sleeper counts toward 100 (`isSleepingLongEnough`), and gets
  up when its bed is gone or the rule no longer lets it sleep (daybreak);
  the environment owner (`Valimc.World.SleepStatus`) hears when it lies
  down, has slept long enough and gets up, and wakes every sleeper once
  enough of them slept. A player also gets up when it leaves the bed, is
  hurt, teleports, dies or disconnects. Getting up frees the bed (a straw
  bed whose rule says so goes), and stands the player up where
  `Valimc.World.StandUp` finds room (above the bed when nowhere), facing it.

  Every tick a player is not asleep adds one to its time since rest
  (`Stats.TIME_SINCE_REST`), which phantoms read; dying resets it.
  """
  alias Valimc.Data.{Blocks, Grid, SleepFacts}
  alias Valimc.Player.{Movement, RespawnPoint}
  alias Valimc.Player.Packets, as: PlayerPackets
  alias Valimc.Protocol.Packets
  alias Valimc.World
  alias Valimc.World.{Clock, Dimension, Region, Spawning, StandUp, View}

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @max_rest 2_147_483_647
  @deep 100
  @steps %{north: {0, -1}, south: {0, 1}, west: {-1, 0}, east: {1, 0}}

  @doc "Whether `player` sleeps."
  def sleeping?(%{sleeping: %{}}), do: true
  def sleeping?(_player), do: false

  ## Lying down

  @doc """
  The player tries to sleep in the bed whose head is at `head` (state
  `bed`), under the dimension's `rule`.
  """
  def start(state, head, bed, rule) do
    player = state.player
    dimension = player.dimension
    facing = facing(bed)
    view = View.new(dimension)

    cond do
      sleeping?(player) or state.life_stage != :alive ->
        state

      not in_range?({player.x, player.y, player.z}, head, facing) ->
        overlay(state, "block.minecraft.bed.too_far_away")

      blocked?(view, head, facing) ->
        overlay(state, "block.minecraft.bed.obstructed")

      true ->
        dark = Spawning.dark?(dimension)

        state =
          if StandUp.sets_spawn?(rule, dark) do
            point = %{
              dimension: dimension,
              position: head,
              yaw: player.yaw,
              pitch: player.pitch,
              forced: false
            }

            RespawnPoint.set(state, point, true)
          else
            state
          end

        cond do
          not StandUp.sleeps?(rule, dark) ->
            problem(state, rule)

          player.game_mode.current != :creative and monsters_near?(head) ->
            overlay(state, "block.minecraft.bed.not_safe")

          true ->
            lie_down(state, view, head, bed)
        end
    end
  end

  defp lie_down(state, view, {x, y, z} = head, bed) do
    foot = behind(head, facing(bed))

    with height when is_float(height) <- sleep_height(view, head, bed),
         [foot_state] when is_integer(foot_state) <- View.blocks(view, [foot]),
         :ok <-
           write(
             state.player.dimension,
             %{head => occupied(bed, true), foot => occupied(foot_state, true)},
             %{head => bed, foot => foot_state}
           ) do
      player = %{
        state.player
        | x: x + 0.5,
          y: y + height + 0.125,
          z: z + 0.5,
          pose: :sleeping
      }

      player = Map.merge(player, %{sleeping: %{bed: head, ticks: 0}, time_since_rest: 0})
      send_packets(state, [PlayerPackets.player_sleeping(player)])
      state = Movement.relocate(state, player)

      state =
        if Valimc.World.GameRules.get(:players_sleeping_percentage) > 100,
          do: overlay(state, "sleep.not_possible"),
          else: state

      Clock.sleep(player.uuid, player.dimension, :asleep, state.connection)
      state
    else
      _ -> state
    end
  end

  # `LivingEntity.startSleeping`'s height: a straw bed's head lies on its foot.
  defp sleep_height(view, head, bed) do
    facts = SleepFacts.bed(name(bed))

    if facts.head_needs_foot do
      [foot] = View.blocks(view, [behind(head, facing(bed))])

      if (foot && name(foot) == name(bed)) and part(foot) == "foot",
        do: facts.foot_height * 1.0
    else
      facts.head_height * 1.0
    end
  end

  @doc """
  `bedInRange`: whether a player at `{x, y, z}` reaches the bed whose head
  is at `head` (facing `facing`): either half's bottom centre within 3
  blocks across and 2 up or down.
  """
  def in_range?({px, py, pz}, head, facing) do
    reach = fn {bx, by, bz} ->
      abs(px - (bx + 0.5)) <= 3.0 and abs(py - by) <= 2.0 and abs(pz - (bz + 0.5)) <= 3.0
    end

    reach.(head) or reach.(behind(head, facing))
  end

  @doc "`bedBlocked`: whether a block over either half of the bed suffocates."
  def blocked?(view, {x, y, z} = head, facing) do
    {fx, fy, fz} = behind(head, facing)

    view
    |> View.blocks([{x, y + 1, z}, {fx, fy + 1, fz}])
    |> Enum.any?(&SleepFacts.suffocating?(&1 || 0))
  end

  # The group's mobs that keep a player from resting near the bed: they are
  # all in the player's own group (groups keep their chunks far apart).
  defp monsters_near?({x, y, z}) do
    {cx, cy, cz} = {x + 0.5, y * 1.0, z + 0.5}
    box = {cx - 8.0, cy - 5.0, cz - 8.0, cx + 8.0, cy + 5.0, cz + 8.0}

    found =
      Valimc.Player.Host.inline(fn group ->
        found =
          Enum.any?(group.sections, fn {_key, %{resource: resource}} ->
            Enum.any?(resource.entities.store.entries, fn
              {_id, %{kind: :mob, body: %{type: type, mob: mob}} = entry} ->
                SleepFacts.rest_preventing?(type) and Valimc.Entity.Mob.alive?(mob) and
                  Valimc.World.Explosion.box_hit?(entry, box)

              _ ->
                false
            end)
          end)

        {found, group}
      end)

    found == {:ok, true}
  end

  ## Each tick

  @doc """
  A player tick: a sleeper's count, its bed and the rule; otherwise one
  more tick since rest.
  """
  def tick(%{player: %{sleeping: %{ticks: ticks} = sleeping} = player} = state) do
    next = min(ticks + 1, @deep)

    if ticks < @deep and next == @deep,
      do: Clock.sleep(player.uuid, player.dimension, :deep, state.connection)

    state = put_in(state.player.sleeping, %{sleeping | ticks: next})
    view = View.new(player.dimension)
    [bed] = View.blocks(view, [sleeping.bed])

    [here] =
      View.blocks(view, [{floor(player.x), floor(player.y), floor(player.z)}])

    cond do
      # `checkBedExists`: a bed that still has a height to lie at.
      bed == nil or SleepFacts.bed(name(bed)) == nil or
          sleep_height(view, sleeping.bed, bed) == nil ->
        stop(state, true)

      here != nil and SleepFacts.bed(name(here)) != nil and
          not StandUp.sleeps?(
            SleepFacts.bed_rule(name(here), player.dimension),
            Spawning.dark?(player.dimension)
          ) ->
        stop(state, false)

      true ->
        state
    end
  end

  def tick(%{player: player} = state) do
    rest = min(Map.get(player, :time_since_rest, 0) + 1, @max_rest)
    %{state | player: Map.put(player, :time_since_rest, rest)}
  end

  ## Getting up

  @doc """
  The player gets up (`stopSleepInBed`): its bed is freed and it stands up
  beside it. `forceful` is vanilla's flag (a hurt or a lost bed). Options:
  `notify: false` when the environment owner woke the player itself,
  `teleport: false` for a player leaving (its client is gone).
  """
  def stop(state, forceful, opts \\ [])

  def stop(%{player: %{sleeping: %{bed: bed}} = player} = state, _forceful, opts) do
    wake = PlayerPackets.wake_up(player.entity_id)

    if Keyword.get(opts, :teleport, true) do
      send_packets(state, [wake])
      Movement.broadcast_player_packet(state, wake)
    end

    view = View.new(player.dimension)

    {x, y, z, yaw, pitch} =
      case View.blocks(view, [bed]) do
        [state_at] when is_integer(state_at) ->
          if SleepFacts.bed(name(state_at)),
            do: free(player, bed, state_at),
            else: {player.x, player.y, player.z, player.yaw, player.pitch}

        _ ->
          {player.x, player.y, player.z, player.yaw, player.pitch}
      end

    player =
      %{player | x: x, y: y, z: z, yaw: yaw, pitch: pitch, pose: :standing}
      |> Map.put(:sleeping, nil)

    if Keyword.get(opts, :notify, true),
      do: Clock.sleep(player.uuid, player.dimension, :awake, state.connection)

    if Keyword.get(opts, :teleport, true) do
      send_packets(state, [PlayerPackets.player_sleeping(player)])
      Movement.relocate(state, player)
    else
      %{state | player: player}
    end
  end

  def stop(state, _forceful, _opts), do: state

  # `LivingEntity.stopSleeping`: the bed is freed (a straw bed may go), and
  # the player stands up beside it facing it, or above it.
  defp free(player, {bx, by, bz} = bed, state_at) do
    dimension = player.dimension
    facing = facing(state_at)
    foot = behind(bed, facing)
    [foot_state] = View.blocks(View.new(dimension), [foot])
    rule = SleepFacts.bed_rule(name(state_at), dimension)

    edits =
      cond do
        rule.destroy_on_leave ->
          Valimc.World.Sounds.play(bed, "minecraft:block.straw_bed.break_leave", :block)
          %{bed => air(), foot => air()}

        foot_state != nil and name(foot_state) == name(state_at) ->
          %{bed => occupied(state_at, false), foot => occupied(foot_state, false)}

        true ->
          %{bed => occupied(state_at, false)}
      end

    _ = write(dimension, edits, Map.take(%{bed => state_at, foot => foot_state}, Map.keys(edits)))

    border = Clock.border(Dimension.name(dimension))

    {x, y, z} =
      StandUp.bed(View.new(dimension), bed, facing, player.yaw, border) ||
        {bx + 0.5, by + 1.1, bz + 0.5}

    {x, y, z, StandUp.look_yaw({x, y, z}, bed), 0.0}
  end

  ## Blocks

  @doc """
  Write `edits` (position => state) where each cell still holds its
  `expected` state, section by section, each fenced on what it read:
  `:ok` or the first refusal.
  """
  def write(dimension, edits, expected) do
    edits
    |> Enum.group_by(fn {{x, _, z}, _} -> Grid.region_key(Grid.chunk_key(x, z)) end)
    |> Enum.reduce_while(:ok, fn {_key, part}, :ok ->
      positions = Enum.map(part, &elem(&1, 0))
      {x, _, z} = hd(positions)

      result =
        with {:ok, owner} <- World.existing_owner(Grid.section(dimension, Grid.chunk_key(x, z))),
             {:ok, observed} <- Region.observe_blocks(owner, positions),
             true <- observed.blocks == Map.take(expected, positions) or {:error, :stale_block},
             {:ok, _} <- Region.set_blocks(owner, observed.fence, Map.new(part)),
             do: :ok

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  @doc "`state` with `occupied` set (a bed's state)."
  def occupied(state, value), do: with_property(state, "occupied", to_string(value))

  @doc "A bed state's facing, as an atom."
  def facing(state), do: String.to_existing_atom(property(state, "facing"))

  @doc "A bed state's part: `\"head\"` or `\"foot\"`."
  def part(state), do: property(state, "part")

  @doc "The cell behind `{x, y, z}` from a bed facing `facing`: the foot of a head."
  def behind({x, y, z}, facing) do
    {dx, dz} = @steps[facing]
    {x - dx, y, z - dz}
  end

  @doc "The cell ahead of `{x, y, z}` toward `facing`: the head of a foot."
  def ahead({x, y, z}, facing) do
    {dx, dz} = @steps[facing]
    {x + dx, y, z + dz}
  end

  @doc "The block name of `state` (without namespace)."
  def name(state), do: Blocks.name(Blocks.block_id(state))

  defp property(state, key), do: state |> Blocks.properties() |> Map.new() |> Map.fetch!(key)

  defp with_property(state, key, value),
    do:
      Blocks.state(name(state), state |> Blocks.properties() |> Map.new() |> Map.put(key, value))

  defp air, do: Blocks.default_state("air")

  @doc "A bed rule's own problem (`BedRule.asProblem`), when it has a message."
  def problem(state, %{error: nil}), do: state
  def problem(state, %{error: key}), do: overlay(state, key)

  @doc "A message above the hotbar, translated from `key`."
  def overlay(state, key) do
    send_packets(state, [Packets.overlay(Valimc.Text.translatable(key))])
    state
  end
end
