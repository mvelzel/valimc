defmodule Valimc.PlayerInteraction do
  @moduledoc "Default mode-derived ranges and pure geometry for the standing preview."
  @path Path.expand("../../priv/protocol/attributes.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @block @facts["minecraft:block_interaction_range"]
  @entity @facts["minecraft:entity_interaction_range"]
  @modes [:survival, :creative, :adventure, :spectator]
  # Native standing eye height is a float before promotion to double.
  @standing_eye_height 1.6200000047683716

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

  def standing_eye(%{x: x, y: y, z: z}), do: {x, y + @standing_eye_height, z}

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
