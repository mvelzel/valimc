defmodule Valimc.Player.SpawnBlocks do
  @moduledoc """
  A player's use of a bed or a respawn anchor (VMC-040a), before the block
  menus and placement, as vanilla's `AbstractBedBlock.useWithoutItem` and
  `RespawnAnchorBlock.useItemOn`/`useWithoutItem` decide it. Spectators,
  and players sneaking with something in a hand, use neither.

  - **Beds** (main hand): a bed missing its other half does nothing. Where
    the dimension's bed rule destroys a bed on use (the Nether and the End)
    it goes: a bed explodes at its head (power 5, with fire, the bad
    respawn point's damage), a straw bed breaks. An occupied bed says so;
    otherwise the player tries to sleep (`Valimc.Player.Sleep`).
  - **Respawn anchors**: glowstone in the using hand charges one below 4
    (the stack shrinks outside creative); with glowstone in the off hand the
    main hand passes so the off hand charges it. A charged anchor used by
    the main hand sets the player's respawn point where anchors work (the
    Nether), and explodes elsewhere, without breaking blocks when water
    beside it would flow into it or stands on it.

  Explosions run at their section's owner after this callback, so every
  player of the group, the user too, is hit through its session.
  """
  alias Valimc.Data.{BlockFacts, Blocks, Grid, SleepFacts}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Input, RespawnPoint, Sleep}
  alias Valimc.Protocol.ItemTypes
  alias Valimc.World
  alias Valimc.World.{Explosion, Sounds, View}

  @glowstone ItemTypes.id("glowstone")

  @doc "The use of the block at `position`: `{:used, state}` or `:pass`."
  def use(state, position, request) do
    player = state.player
    main = Inventory.held(state.inventory, :main)
    off = Inventory.held(state.inventory, :off)
    suppressed = Input.pressed?(player.input, :shift) and (main != nil or off != nil)

    with false <- player.game_mode.current == :spectator or suppressed,
         [block] when is_integer(block) <- View.blocks(View.new(player.dimension), [position]) do
      name = Sleep.name(block)

      cond do
        name == "respawn_anchor" ->
          anchor(state, position, block, request, off)

        SleepFacts.bed(name) != nil and request.hand == :main ->
          {:used, bed(state, position, block)}

        true ->
          :pass
      end
    else
      _ -> :pass
    end
  end

  ## Beds

  defp bed(state, position, block) do
    dimension = state.player.dimension
    facing = Sleep.facing(block)
    part = Sleep.part(block)

    other =
      if part == "foot", do: Sleep.ahead(position, facing), else: Sleep.behind(position, facing)

    view = View.new(dimension)
    [other_state] = View.blocks(view, [other])

    if other_state != nil and Sleep.name(other_state) == Sleep.name(block) and
         Sleep.part(other_state) != part do
      {head, head_state} = if part == "head", do: {position, block}, else: {other, other_state}
      rule = SleepFacts.bed_rule(Sleep.name(block), dimension)

      cond do
        rule.destroy_on_use ->
          state |> Sleep.problem(rule) |> destroy(head, head_state)

        property(head_state, "occupied") == "true" ->
          Sleep.overlay(state, "block.minecraft.bed.occupied")

        true ->
          Sleep.start(state, head, head_state, rule)
      end
    else
      state
    end
  end

  # `destroyOnUse`: both halves go; a bed explodes at its head, a straw bed breaks.
  defp destroy(state, head, head_state) do
    dimension = state.player.dimension
    foot = Sleep.behind(head, Sleep.facing(head_state))
    [foot_state] = View.blocks(View.new(dimension), [foot])
    air = Blocks.default_state("air")

    {edits, expected} =
      if foot_state != nil and Sleep.name(foot_state) == Sleep.name(head_state),
        do: {%{head => air, foot => air}, %{head => head_state, foot => foot_state}},
        else: {%{head => air}, %{head => head_state}}

    if Sleep.write(dimension, edits, expected) == :ok do
      if SleepFacts.bed(Sleep.name(head_state)).explodes,
        do: explode(state, head, Explosion.respawn_point(head)),
        else: Sounds.play(head, "minecraft:block.straw_bed.break_leave", :block)
    end

    state
  end

  ## Respawn anchors

  defp anchor(state, position, block, request, off) do
    charges = String.to_integer(property(block, "charges"))
    held = Inventory.held(state.inventory, request.hand)

    cond do
      glowstone?(held) and charges < 4 ->
        charged = Blocks.state("respawn_anchor", %{"charges" => Integer.to_string(charges + 1)})

        if Sleep.write(state.player.dimension, %{position => charged}, %{position => block}) ==
             :ok do
          Sounds.play(position, "minecraft:block.respawn_anchor.charge", :block)
          {:used, consume(state, request.hand)}
        else
          {:used, state}
        end

      request.hand == :main and glowstone?(off) and charges < 4 ->
        :pass

      request.hand != :main or charges == 0 ->
        :pass

      not SleepFacts.dimension(state.player.dimension).respawn_anchor_works ->
        {:used, blow_up(state, position, block)}

      true ->
        point = %{
          dimension: state.player.dimension,
          position: position,
          yaw: 0.0,
          pitch: 0.0,
          forced: false
        }

        if RespawnPoint.same?(point, Map.get(state.player, :respawn)) do
          {:used, state}
        else
          Sounds.play(position, "minecraft:block.respawn_anchor.set_spawn", :block)
          {:used, RespawnPoint.set(state, point, true)}
        end
    end
  end

  # `RespawnAnchorBlock.explode`: the anchor goes, then explodes; water that
  # would flow into its cell (or stands above it) keeps every block.
  defp blow_up(state, {x, y, z} = position, block) do
    dimension = state.player.dimension
    air = Blocks.default_state("air")

    if Sleep.write(dimension, %{position => air}, %{position => block}) == :ok do
      view = View.new(dimension)
      sides = [{x, y, z - 1}, {x, y, z + 1}, {x - 1, y, z}, {x + 1, y, z}]
      [above | states] = View.blocks(view, [{x, y + 1, z} | sides])
      below = View.blocks(view, Enum.map(sides, fn {a, b, c} -> {a, b - 1, c} end))

      wet =
        water?(above) or
          Enum.any?(Enum.zip(states, below), fn {side, under} -> flows?(side, under) end)

      explode(state, position, Explosion.respawn_point(position, not wet))
    end

    state
  end

  # `isWaterThatWouldFlow`: a water source, or flowing water of at least two
  # with no water below it.
  defp flows?(state, below) do
    fluid = BlockFacts.fluid(state || 0)

    cond do
      fluid.kind != :water -> false
      fluid.source -> true
      fluid.amount < 2 -> false
      true -> not water?(below)
    end
  end

  defp water?(state), do: BlockFacts.fluid(state || 0).kind == :water

  # The explosion runs at the owner of its section once this callback ends.
  defp explode(state, {x, _, z}, explosion) do
    with {:ok, {pid, epoch}} <-
           World.existing_owner(Grid.section(state.player.dimension, Grid.chunk_key(x, z))),
         do: send(pid, {:resource, epoch, {:explode, explosion}})

    state
  end

  defp glowstone?(stack), do: stack != nil and stack.item_id == @glowstone

  defp consume(%{inventory: %{infinite_materials: true}} = state, _hand), do: state

  defp consume(state, hand) do
    slot = if hand == :main, do: 36 + state.inventory.selected, else: 45
    stack = Inventory.held(state.inventory, hand)
    next = if stack.count > 1, do: %{stack | count: stack.count - 1}
    %{state | inventory: Inventory.put(state.inventory, slot, next)}
  end

  defp property(state, key), do: state |> Blocks.properties() |> Map.new() |> Map.fetch!(key)
end
