defmodule Valimc.World.StandUp do
  @moduledoc """
  Where a player stands up from a bed or respawns at a bed or anchor
  (VMC-040a), as vanilla's `AbstractBedBlock.findStandUpPosition`,
  `RespawnAnchorBlock.findStandUpPosition` and
  `DismountHelper.findSafeDismountLocation` find it: the first cell of a
  fixed ring of offsets where a standing player fits on the cell's floor,
  first avoiding dangerous blocks, then not. Cells are read from `view`
  (`Valimc.World.View`, published snapshots or supplied states); a cell that
  cannot be read is air, and a box the kernel cannot read is not safe.

  The search's inputs per state come from `Valimc.Data.SleepFacts`; the
  player's box collides with blocks only, with no entity context, and must
  lie inside the world border.
  """
  alias Valimc.AI.Mth, as: AIMth
  alias Valimc.Data.{Blocks, Float32, Mth, SleepFacts}
  alias Valimc.Physics.{CollisionContext, Kernel}
  alias Valimc.World.Border

  # A standing player's box: 0.6F wide and 1.8F high, widened to doubles.
  @half_width 0.30000001192092896
  @height 1.7999999523162842
  # `1.0E-5F` widened (`WorldBorder.isWithinBounds(AABB)`).
  @border_margin 9.999999747378752e-6
  @radians Float32.round(:math.pi() / 180.0)
  # `Mth.RAD_TO_DEG`, a float constant.
  @degrees 57.2957763671875

  @steps %{north: {0, -1}, south: {0, 1}, west: {-1, 0}, east: {1, 0}}
  @clockwise %{north: :east, east: :south, south: :west, west: :north}
  @opposite %{north: :south, south: :north, west: :east, east: :west}

  # Anchors: the horizontal ring, the ring below, the ring above, then the cell above.
  @ring [{0, -1}, {-1, 0}, {0, 1}, {1, 0}, {-1, -1}, {1, -1}, {-1, 1}, {1, 1}]
  @anchor_offsets for(dy <- [0, -1, 1], {dx, dz} <- @ring, do: {dx, dy, dz}) ++ [{0, 1, 0}]

  @doc """
  Where a player stands up from the bed whose head is at `head` (facing
  `facing`, an atom) when it looks at `yaw`: `{x, y, z}` or nil.
  """
  def bed(view, {x, y, z} = head, facing, yaw, border \\ nil) do
    right = @clockwise[facing]
    side = if facing_angle?(right, yaw), do: @opposite[right], else: right
    forward = @steps[facing]
    side = @steps[side]
    surround = surround(forward, side)

    if bed_state?(state(view, {x, y - 1, z})) do
      above = above(forward)
      below = {x, y - 1, z}

      Enum.find_value(
        [
          {head, surround, true},
          {below, surround, true},
          {head, above, true},
          {head, surround, false},
          {below, surround, false},
          {head, above, false}
        ],
        fn {cell, offsets, check} -> at_offsets(view, cell, offsets, check, border) end
      )
    else
      offsets = surround ++ above(forward)

      at_offsets(view, head, offsets, true, border) ||
        at_offsets(view, head, offsets, false, border)
    end
  end

  @doc "Where a player respawns at the anchor at `{x, y, z}`: `{x, y, z}` or nil."
  def anchor(view, {x, y, z}, border \\ nil) do
    find = fn check ->
      Enum.find_value(@anchor_offsets, fn {dx, dy, dz} ->
        safe(view, {x + dx, y + dy, z + dz}, check, border)
      end)
    end

    find.(true) || find.(false)
  end

  @doc """
  Where a player whose respawn point is `point` (`%{position, yaw}`, in
  `dimension`) respawns (`ServerPlayer.findRespawnAndUseSpawnBlock`, not
  forced): `{position, yaw, pitch, charged}` with `charged` the anchor's
  state after it spends a charge (nil for a bed), or nil when the block is
  missing, spent or blocked. A bed counts when its rule there sets spawns
  (`dark` answers `when_dark`); an anchor when it has a charge and anchors
  work there.
  """
  def respawn(view, dimension, %{position: position, yaw: yaw}, dark \\ false, border \\ nil) do
    state = state(view, position)
    name = Blocks.name(Blocks.block_id(state))
    properties = Map.new(Blocks.properties(state))

    cond do
      name == "respawn_anchor" ->
        charges = String.to_integer(properties["charges"])

        with true <- charges > 0 and SleepFacts.dimension(dimension).respawn_anchor_works,
             {_, _, _} = at <- anchor(view, position, border) do
          spent = Blocks.state("respawn_anchor", %{"charges" => Integer.to_string(charges - 1)})
          {at, look_yaw(at, position), 0.0, spent}
        else
          _ -> nil
        end

      SleepFacts.bed(name) != nil and sets_spawn?(SleepFacts.bed_rule(name, dimension), dark) ->
        facing = String.to_existing_atom(properties["facing"])

        case bed(view, position, facing, yaw, border) do
          nil -> nil
          at -> {at, look_yaw(at, position), 0.0, nil}
        end

      true ->
        nil
    end
  end

  @doc "Whether a bed rule lets a bed set the spawn (`BedRule.canSetSpawn`)."
  def sets_spawn?(%{can_set_spawn: rule}, dark), do: test(rule, dark)

  @doc "Whether a bed rule lets a player sleep (`BedRule.canSleep`)."
  def sleeps?(%{can_sleep: rule}, dark), do: test(rule, dark)

  defp test(:always, _dark), do: true
  defp test(:when_dark, dark), do: dark
  defp test(:never, _dark), do: false

  @doc """
  The yaw that looks from `position` at the bottom centre of `block`
  (`RespawnPosAngle.calculateLookAtYaw`, `LivingEntity.stopSleeping`).
  """
  def look_yaw({px, py, pz}, {bx, by, bz}) do
    {dx, dy, dz} = {bx + 0.5 - px, by - py, bz + 0.5 - pz}
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)

    {dx, dz} =
      if length < 9.999999747378752e-6, do: {0.0, 0.0}, else: {dx / length, dz / length}

    Float32.round(wrap(AIMth.atan2(dz, dx) * @degrees - 90.0))
  end

  @doc """
  `findSafeDismountLocation` for a player at `cell`: its floor's position
  `{x, y, z}` when a standing player fits there, nil otherwise; with
  `check`, dangerous blocks there and below are refused.
  """
  def safe(view, {x, y, z} = cell, check, border \\ nil) do
    state = state(view, cell)
    below = state(view, {x, y - 1, z})

    with false <- check and SleepFacts.dangerous?(state),
         floor when is_float(floor) and floor < 1.0 <- floor(state, below),
         false <- check and floor <= 0.0 and SleepFacts.dangerous?(below),
         position = {x + 0.5, y + floor, z + 0.5},
         box = box(position),
         {:ok, false} <- Kernel.colliding?(view, box, CollisionContext.empty()),
         false <- SleepFacts.invalid_inside?(state),
         false <- SleepFacts.invalid_inside?(state(view, {x, y + 1, z})),
         true <- within_border?(border, box) do
      position
    else
      _ -> nil
    end
  end

  defp at_offsets(view, {x, y, z}, offsets, check, border) do
    Enum.find_value(offsets, fn {dx, dz} -> safe(view, {x + dx, y, z + dz}, check, border) end)
  end

  # `bedSurroundStandUpOffsets`.
  defp surround({fx, fz}, {sx, sz}) do
    [
      {sx, sz},
      {sx - fx, sz - fz},
      {sx - fx * 2, sz - fz * 2},
      {-fx * 2, -fz * 2},
      {-sx - fx * 2, -sz - fz * 2},
      {-sx - fx, -sz - fz},
      {-sx, -sz},
      {-sx + fx, -sz + fz},
      {fx, fz},
      {sx + fx, sz + fz}
    ]
  end

  # `bedAboveStandUpOffsets`.
  defp above({fx, fz}), do: [{0, 0}, {-fx, -fz}]

  # `BlockGetter.getBlockFloorHeight` over non-climbable shapes.
  defp floor(state, below) do
    case SleepFacts.floor(state) do
      nil ->
        case SleepFacts.floor(below) do
          height when is_float(height) and height >= 1.0 -> height - 1.0
          _ -> nil
        end

      height ->
        height * 1.0
    end
  end

  defp box({x, y, z}),
    do: {x - @half_width, y, z - @half_width, x + @half_width, y + @height, z + @half_width}

  defp within_border?(nil, _box), do: true

  defp within_border?(border, {x0, _, z0, x1, _, z1}),
    do:
      Border.within?(border, x0, z0) and
        Border.within?(border, x1 - @border_margin, z1 - @border_margin)

  # `Direction.isFacingAngle`: float arithmetic over `Mth`'s sine table.
  defp facing_angle?(direction, yaw) do
    {nx, nz} = @steps[direction]
    radians = Float32.round(yaw * @radians)
    dx = -Mth.sin(radians)
    dz = Mth.cos(radians)
    Float32.round(Float32.round(nx * dx) + Float32.round(nz * dz)) > 0.0
  end

  defp wrap(angle) do
    a = :math.fmod(angle, 360.0)
    a = if a >= 180.0, do: a - 360.0, else: a
    if a < -180.0, do: a + 360.0, else: a
  end

  defp state(view, position) do
    case Valimc.World.View.blocks(view, [position]) do
      [state] when is_integer(state) -> state
      _ -> 0
    end
  end

  defp bed_state?(state), do: SleepFacts.bed(Blocks.name(Blocks.block_id(state))) != nil
end
