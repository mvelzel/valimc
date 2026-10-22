defmodule Valimc.Blocks.Placement do
  @moduledoc """
  Block placement (VMC-029d) from the generated placement facts
  (`PlacementOracle`, `priv/physics/placement.json`): which cell a click
  targets and the click's inputs, for the owner's placement rules
  (`Valimc.World.BlockRules.place/7`), which read the cells around the target
  and say what vanilla's `BlockItem.useOn` writes there.

  A click replaces the clicked block when the clicked state's replacement
  rule says so (`BlockPlaceContext.replaceClicked`), else it targets the cell
  beside the clicked face. The inputs are the context's: the clicked face,
  whether it replaces, the player's `Direction.orderedByNearest` order,
  vertical and horizontal direction, its rotation, the cursor, sneaking; the
  owner adds the target's light and redstone power.
  """
  import Bitwise
  alias Valimc.Data.Float32
  use Valimc.Data.Facts, "physics/placement.json"
  alias Valimc.Data.BlockFacts
  @count BlockFacts.count()

  unless @facts["state_count"] == @count, do: raise("Placement facts of another registry")

  @items MapSet.new(@facts["items"], &hd/1)
  @operator MapSet.new(@facts["operator"])
  @buckets MapSet.new(@facts["buckets"])
  @on_water MapSet.new(@facts["on_water"])
  @orders @facts["orders"] |> Enum.with_index() |> Map.new()
  @rotations @facts["rotations"]
             |> Enum.with_index()
             |> Map.new(fn {[segment, horizontal], index} -> {{segment, horizontal}, index} end)
  @block_items Map.new(@facts["replacement"]["items"], &List.to_tuple/1)
  # Replacement rules by id: 0 never, 1 always, then each `{inputs, table}`.
  @replacement_rules @facts["replacement"]["rules"]
                     |> Enum.map(fn rule -> {rule["vars"], rule["table"]} end)
                     |> List.to_tuple()
  @replacement for [first, last, rule] <- @facts["replacement"]["states"],
                   into: <<>>,
                   do: :binary.copy(<<rule>>, last - first + 1)

  unless map_size(@orders) == 48 and map_size(@rotations) == 20 and
           byte_size(@replacement) == @count and
           Enum.all?(@facts["replacement"]["states"], fn [_, _, rule] ->
             rule < tuple_size(@replacement_rules) + 2
           end),
         do: raise("Invalid placement facts")

  @domains %{"own" => 2, "face" => 6, "cursor" => 27, "secondary" => 2}

  @doc "Whether vanilla places `item` by a click on a block, as the facts model it."
  def placeable?(item), do: MapSet.member?(@items, item)

  @doc "Whether only players who may use operator blocks place `item` (`GameMasterBlockItem`)."
  def operator?(item), do: MapSet.member?(@operator, item)

  @doc "Whether placing `item` leaves an empty bucket (`SolidBucketItem`)."
  def bucket?(item), do: MapSet.member?(@buckets, item)

  @doc """
  Whether `item` places by use on the water source looked at, as a click on
  the cell above it, and not by a click on a block (`PlaceOnWaterBlockItem`:
  lily pads, frogspawn).
  """
  def on_water?(item), do: MapSet.member?(@on_water, item)

  @doc """
  Whether a held stack places. A block entity's data from a stack (a name,
  patterns, contents) needs its owned record first (VMC-032), so stacks of
  blocks with a block entity place only without component changes.
  """
  def placeable_stack?(%Valimc.Protocol.ItemStack{item_id: item, components: components}) do
    placeable?(item) and
      (components == %{} or
         not Valimc.Blocks.BlockEntityTypes.native?(Valimc.Protocol.Data.item_block(item) || 0))
  end

  def placeable_stack?(_), do: false

  @doc """
  The cell a click of `item` on `clicked` targets and the click's inputs for
  the placement rules (`request`: position, face, cursor, yaw, pitch and
  `secondary`, sneaking): `{:ok, %{position, replace_clicked, values}}`.
  """
  def target(
        item,
        clicked,
        %{position: {x, y, z} = position, face: face, cursor: {_, _, _} = cursor} = request
      )
      when is_integer(item) and is_integer(clicked) and clicked >= 0 and clicked < @count and
             face in 0..5 and is_integer(x) and is_integer(y) and is_integer(z) do
    secondary = Map.get(request, :secondary, false)
    cursor_class = cursor_class(cursor)
    replace = replaces?(clicked, item, face, cursor_class, secondary)
    target = if replace, do: position, else: offset(position, face)
    {:ok, %{position: target, replace_clicked: replace, values: values(request, replace)}}
  end

  def target(_, _, _), do: {:error, :invalid_context}

  def adjacent(%{position: position, face: face}) when face in 0..5,
    do: offset(position, face)

  @doc "Whether any block item replaces `state` (air, fluids, replaceable plants)."
  def replaceable?(state), do: BlockFacts.replaceability(state) == 2

  # `replaceClicked`: the clicked state's replacement rule over whether the
  # held item is its block's own, the face, the cursor and sneaking.
  defp replaces?(state, item, face, cursor, secondary) do
    case :binary.at(@replacement, state) do
      0 ->
        false

      1 ->
        true

      rule ->
        {vars, table} = elem(@replacement_rules, rule - 2)
        own = Map.get(@block_items, Valimc.Data.Blocks.block_id(state)) == item

        inputs = %{
          "own" => b(own),
          "face" => face,
          "cursor" => cursor,
          "secondary" => b(secondary)
        }

        index =
          Enum.reduce(vars, 0, fn var, index ->
            index * Map.fetch!(@domains, var) + Map.fetch!(inputs, var)
          end)

        :binary.at(table, index) == ?1
    end
  end

  defp b(true), do: 1
  defp b(false), do: 0

  # Per axis whether the cursor is below, at or above the block's middle.
  defp cursor_class({cx, cy, cz}), do: half(cx) * 9 + half(cy) * 3 + half(cz)

  defp half(v) when v < 0.5, do: 0
  defp half(v) when v == 0.5, do: 1
  defp half(_), do: 2

  @doc """
  The inputs by `placement::VARS`: order, vertical, horizontal, rotation,
  cursor, secondary, face, replace, the target's light and redstone power
  (which the owner fills in), and whether the click was inside the block.
  """
  def values(%{face: face, cursor: cursor} = request, replace) do
    {yaw, pitch} = {request.yaw * 1.0, request.pitch * 1.0}
    order = Map.fetch!(@orders, ordered_by_nearest(yaw, pitch))
    # `Direction.getFacingAxis(player, Y)`
    vertical = if pitch < 0.0, do: 1, else: 0
    horizontal = from_y_rot(yaw)
    rotation = Map.fetch!(@rotations, {segment(yaw), horizontal})
    secondary = if Map.get(request, :secondary, false), do: 1, else: 0

    [
      order,
      vertical,
      horizontal,
      rotation,
      cursor_class(cursor),
      secondary,
      face,
      b(replace),
      0,
      0,
      0,
      0,
      b(Map.get(request, :inside, false))
    ]
  end

  # `Direction.fromYRot`, as a 2D data value (south, west, north, east).
  defp from_y_rot(yaw), do: Integer.mod(floor(yaw / 90.0 + 0.5), 4)

  # `RotationSegment.convertToSegment`: `Math.round(yaw * (16 / 360f)) & 15` in float.
  defp segment(yaw) do
    scaled = Float32.round(Float32.round(yaw) * Float32.round(16 / 360))
    floor(Float32.round(scaled + 0.5)) &&& 15
  end

  # `Direction.orderedByNearest`, in float as vanilla computes it with `Mth`:
  # down, up, north, south, west, east as 0..5.
  defp ordered_by_nearest(yaw, pitch) do
    pitch = Float32.round(pitch * Float32.round(:math.pi() / 180.0))
    yaw = Float32.round(-yaw * Float32.round(:math.pi() / 180.0))
    {pitch_sin, pitch_cos} = {mth_sin(pitch), mth_cos(pitch)}
    {yaw_sin, yaw_cos} = {mth_sin(yaw), mth_cos(yaw)}
    {x_pos, y_pos, z_pos} = {yaw_sin > 0.0, pitch_sin < 0.0, yaw_cos > 0.0}
    x_yaw = if x_pos, do: yaw_sin, else: -yaw_sin
    y_mag = if y_pos, do: -pitch_sin, else: pitch_sin
    z_yaw = if z_pos, do: yaw_cos, else: -yaw_cos
    {x_mag, z_mag} = {Float32.round(x_yaw * pitch_cos), Float32.round(z_yaw * pitch_cos)}

    {ax, ay, az} =
      {if(x_pos, do: 5, else: 4), if(y_pos, do: 1, else: 0), if(z_pos, do: 3, else: 2)}

    [a, b, c] =
      cond do
        x_yaw > z_yaw and y_mag > x_mag -> [ay, ax, az]
        x_yaw > z_yaw and z_mag > y_mag -> [ax, az, ay]
        x_yaw > z_yaw -> [ax, ay, az]
        y_mag > z_mag -> [ay, az, ax]
        x_mag > y_mag -> [az, ax, ay]
        true -> [az, ay, ax]
      end

    [a, b, c, bxor(c, 1), bxor(b, 1), bxor(a, 1)]
  end

  # `Mth.sin` and `Mth.cos`: a 65,536-entry table of float sines.
  defp mth_sin(v), do: sine(trunc(Float32.round(v * 10430.378)))
  defp mth_cos(v), do: sine(trunc(Float32.round(v * 10430.378 + 16384.0)))
  defp sine(i), do: Float32.round(:math.sin(band(i, 65535) * :math.pi() * 2.0 / 65536.0))

  defp offset({x, y, z}, 0), do: {x, y - 1, z}
  defp offset({x, y, z}, 1), do: {x, y + 1, z}
  defp offset({x, y, z}, 2), do: {x, y, z - 1}
  defp offset({x, y, z}, 3), do: {x, y, z + 1}
  defp offset({x, y, z}, 4), do: {x - 1, y, z}
  defp offset({x, y, z}, 5), do: {x + 1, y, z}
end
