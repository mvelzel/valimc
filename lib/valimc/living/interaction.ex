defmodule Valimc.Living.Interaction do
  @moduledoc "Default mode-derived ranges and pure geometry using the selected player pose."
  @block Valimc.Living.Attributes.fetch("block_interaction_range")
  @entity Valimc.Living.Attributes.fetch("entity_interaction_range")
  @modes [:survival, :creative, :adventure, :spectator]

  def opens_block_menu?(mode, hand, secondary, main, off)
      when mode in @modes and hand in [:main, :off] and is_boolean(secondary) and
             is_boolean(main) and is_boolean(off),
      do: mode == :spectator or (hand == :main and not (secondary and (main or off)))

  def opens_block_menu?(_, _, _, _, _), do: false

  def block_range(:creative), do: @block["default"] + 0.5
  def block_range(mode) when mode in @modes, do: @block["default"]
  def entity_range(:creative), do: @entity["default"] + 2.0
  def entity_range(mode) when mode in @modes, do: @entity["default"]

  def attributes(mode) when mode in @modes do
    [
      {@block["id"], @block["default"],
       if(mode == :creative, do: [{"minecraft:creative_mode_block_range", 0.5, 0}], else: [])},
      {@entity["id"], @entity["default"],
       if(mode == :creative, do: [{"minecraft:creative_mode_entity_range", 2.0, 0}], else: [])}
    ]
  end

  def eye(%{x: x, y: y, z: z} = player) do
    {:ok, geometry} =
      Valimc.Data.PlayerPose.geometry(Map.get(player, :pose, :standing), {x, y, z})

    geometry.eye
  end

  def block_distance_squared({ex, ey, ez}, {x, y, z}) do
    dx = max(max(x - ex, ex - (x + 1)), 0.0)
    dy = max(max(y - ey, ey - (y + 1)), 0.0)
    dz = max(max(z - ez, ez - (z + 1)), 0.0)
    dx * dx + dy * dy + dz * dz
  end

  def within_block?(mode, eye, block, buffer \\ 1.0) do
    range = block_range(mode) + buffer
    block_distance_squared(eye, block) < range * range
  end

  def valid_hit?({x, y, z}, {cx, cy, cz}) do
    # Preserve native translate-then-subtract arithmetic, including remote coordinates.
    abs(x + cx - (x + 0.5)) < 1.0000001 and
      abs(y + cy - (y + 0.5)) < 1.0000001 and
      abs(z + cz - (z + 0.5)) < 1.0000001
  end

  def valid_hit?(block, <<cx::float-32, cy::float-32, cz::float-32>>),
    do: valid_hit?(block, {cx, cy, cz})

  # BEAM float matching excludes NaN/infinity. Native hit validation ignores them.
  def valid_hit?(_, _), do: false
end
