defmodule Valimc.Blocks.Placement do
  @moduledoc """
  Pure native placement candidates; owners still admit geometry, writes and
  consumption. The placed state comes from the item's block behaviour
  (`Valimc.Blocks`); this module owns the generated placement facts.
  """
  @chest_item Valimc.Protocol.Data.item("chest")
  @cooking_items Enum.map(~w(furnace smoker blast_furnace), &Valimc.Protocol.Data.item/1)
  @facing_items [@chest_item | @cooking_items]
  alias Valimc.Data.Float32
  use Valimc.Data.Facts, "physics/placement.json"
  alias Valimc.Data.BlockFacts
  @count BlockFacts.count()

  @plain Map.new(@facts["plain"], fn {item, state} -> {String.to_integer(item), state} end)
  @slabs Map.new(@facts["slabs"], fn row -> {row["item"], List.to_tuple(row["states"])} end)
  @pillars Map.new(@facts["pillars"], fn row -> {row["item"], List.to_tuple(row["states"])} end)
  @slab_states @facts["slabs"]
               |> Enum.flat_map(fn row ->
                 Enum.with_index(row["states"], fn state, index ->
                   {state, {row["item"], div(index, 2)}}
                 end)
               end)
               |> Map.new()
  unless map_size(@plain) == 190 and map_size(@slabs) == 101 and map_size(@pillars) == 60 and
           map_size(@slab_states) == 606 and
           Enum.all?(@slabs, fn {_item, states} -> tuple_size(states) == 6 end) and
           Enum.all?(@plain, fn {_item, state} ->
             is_integer(state) and state in 0..(@count - 1) and
               BlockFacts.replaceability(state) == 1
           end) and
           Enum.all?(@slab_states, fn {state, _} ->
             is_integer(state) and state in 0..(@count - 1) and
               BlockFacts.replaceability(state) == 3
           end) and
           Enum.all?(@pillars, fn {_item, states} ->
             tuple_size(states) == 3 and
               Enum.all?(Tuple.to_list(states), fn state ->
                 is_integer(state) and state in 0..(@count - 1) and
                   BlockFacts.replaceability(state) == 1
               end)
           end),
         do: raise("Invalid placement facts")

  # Class-keyed behaviours must choose the same placement as the item tables.
  unless Enum.all?(Map.keys(@slabs), &(Valimc.Blocks.item_behaviour(&1) == Valimc.Blocks.Slab)) and
           Enum.all?(
             Map.keys(@pillars),
             &(Valimc.Blocks.item_behaviour(&1) == Valimc.Blocks.Pillar)
           ) and
           Enum.all?(
             Map.keys(@plain),
             &(Valimc.Blocks.item_behaviour(&1) in [
                 Valimc.Blocks.Default,
                 Valimc.Blocks.Coral,
                 Valimc.Blocks.BuddingAmethyst
               ])
           ) and
           Valimc.Blocks.item_behaviour(@chest_item) == Valimc.Blocks.Chest and
           Enum.all?(@cooking_items, &(Valimc.Blocks.item_behaviour(&1) == Valimc.Blocks.Furnace)) and
           Enum.all?(Map.keys(@slab_states), &(Valimc.Blocks.behaviour(&1) == Valimc.Blocks.Slab)),
         do: raise("Block behaviours disagree with the placement facts")

  @doc "Propose a state from an immutable clicked/adjacent sample, without granting a world write."
  def candidate(
        item,
        clicked,
        adjacent,
        %{
          position: {x, y, z} = position,
          face: face,
          cursor: {_cx, cy, _cz}
        } = request
      )
      when is_integer(item) and is_integer(clicked) and clicked >= 0 and clicked < @count and
             is_integer(adjacent) and adjacent >= 0 and adjacent < @count and
             is_integer(face) and face in 0..5 and is_integer(x) and is_integer(y) and
             is_integer(z) and x in -33_554_432..33_554_431 and y in -2048..2047 and
             z in -33_554_432..33_554_431 and is_number(cy) do
    if supported_item?(item) do
      # Native hit coordinates are translated to double before relative height is tested.
      upper = y + cy - y > 0.5

      with {:ok, replace} <- replaceable(clicked, item, face, upper, true),
           target = if(replace, do: position, else: offset(position, face)),
           state = if(replace, do: clicked, else: adjacent),
           {:ok, true} <-
             if(replace, do: {:ok, true}, else: replaceable(state, item, face, upper, false)),
           {:ok, placed} <- candidate_state(item, state, face, upper, request) do
        {:ok, %{position: target, state: placed, replace_clicked: replace}}
      else
        {:ok, false} -> {:error, :occupied}
        error -> error
      end
    else
      {:error, :unsupported_item}
    end
  end

  def candidate(_, _, _, _), do: {:error, :invalid_context}

  def adjacent(%{position: position, face: face}) when face in 0..5,
    do: offset(position, face)

  @doc "Whether any block item replaces `state` (air, fluids, replaceable plants)."
  def replaceable?(state), do: BlockFacts.replaceability(state) == 2

  def supported_item?(item),
    do:
      item in @facing_items or Map.has_key?(@plain, item) or Map.has_key?(@slabs, item) or
        Map.has_key?(@pillars, item)

  @doc "Container names need owned metadata and loot-copy support before item consumption."
  def supported_stack?(%Valimc.Protocol.ItemStack{item_id: item, components: components})
      when item in @facing_items,
      do: not Map.has_key?(components, "minecraft:custom_name")

  def supported_stack?(%Valimc.Protocol.ItemStack{item_id: item}), do: supported_item?(item)
  def supported_stack?(_), do: false

  @directions ~w(down up north south west east)

  @doc """
  The states a creative block item without modelled placement tries beside
  the clicked face, in order; the owner places the first that can survive
  (`BlockItem.canPlace`). A ladder follows `LadderBlock.getStateForPlacement`:
  never on the front of the ladder it was used on, else each horizontal
  direction the player looks along, facing away from it (waterlogged in
  water); any other block its default state. `[]` places nothing.
  """
  def creative_states(block, clicked, adjacent, %{face: face} = request) do
    if Valimc.Data.Blocks.class(block) == "LadderBlock" do
      on_front =
        Valimc.Data.Blocks.block_id(clicked) == Valimc.Data.Blocks.block_id(block) and
          Map.new(Valimc.Data.Blocks.properties(clicked))["facing"] ==
            Enum.at(@directions, face)

      water = BlockFacts.fluid(adjacent)
      waterlogged = to_string(water.kind == :water and water.source)

      if on_front,
        do: [],
        else:
          for(
            d <- nearest_looking(request),
            d >= 2,
            do:
              Valimc.Data.Blocks.state(
                Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(block)),
                %{
                  "facing" => Enum.at(@directions, Bitwise.bxor(d, 1)),
                  "waterlogged" => waterlogged
                }
              )
          )
    else
      [block]
    end
  end

  # `BlockPlaceContext.getNearestLookingDirections` beside the clicked face:
  # `Direction.orderedByNearest(player)` with the face's opposite moved first.
  defp nearest_looking(%{face: face} = request) do
    opposite = Bitwise.bxor(face, 1)
    [opposite | List.delete(ordered_by_nearest(request.yaw, request.pitch), opposite)]
  end

  # `Direction.orderedByNearest`, in float as vanilla computes it with `Mth`.
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
    # down, up, north, south, west, east
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

    [a, b, c, Bitwise.bxor(c, 1), Bitwise.bxor(b, 1), Bitwise.bxor(a, 1)]
  end

  # `Mth.sin` and `Mth.cos`: a 65,536-entry table of float sines.
  defp mth_sin(v), do: sine(trunc(Float32.round(v * 10430.378)))
  defp mth_cos(v), do: sine(trunc(Float32.round(v * 10430.378 + 16384.0)))
  defp sine(i), do: Float32.round(:math.sin(Bitwise.band(i, 65535) * :math.pi() * 2.0 / 65536.0))

  defp candidate_state(item, state, face, upper, request),
    do: Valimc.Blocks.placement(item, state, face, upper, request)

  @doc "Placement facts read by the block behaviours."
  def plain_state(item), do: Map.fetch!(@plain, item)
  def slab_states(item), do: Map.fetch!(@slabs, item)
  def slab_half(state), do: Map.get(@slab_states, state)
  def pillar_states(item), do: Map.fetch!(@pillars, item)

  defp replaceable(state, item, face, upper, clicked) do
    case BlockFacts.replaceability(state) do
      0 ->
        {:error, :unsupported_replacement}

      1 ->
        {:ok, false}

      2 ->
        {:ok, true}

      3 ->
        {:ok, Valimc.Blocks.replaceable?(state, item, face, upper, clicked)}
    end
  end

  defp offset({x, y, z}, 0), do: {x, y - 1, z}
  defp offset({x, y, z}, 1), do: {x, y + 1, z}
  defp offset({x, y, z}, 2), do: {x, y, z - 1}
  defp offset({x, y, z}, 3), do: {x, y, z + 1}
  defp offset({x, y, z}, 4), do: {x - 1, y, z}
  defp offset({x, y, z}, 5), do: {x + 1, y, z}
end
