defmodule Valimc.Portal.EndPortal do
  @moduledoc """
  End portals (VMC-026b3), as vanilla's `EnderEyeItem.useOn`,
  `EndPortalFrameBlock.getOrCreatePortalShape` and `EndPortalBlock` make and
  use them:

  - An eye of ender used on a frame without one fills it; when twelve frames
    with eyes face a 3 × 3 opening from its four sides (corners free), the
    opening becomes end portal blocks. The search is vanilla's pattern match
    over the 5 × 5 × 5 corners at and above the clicked frame.
  - Entering one outside the End leads to the End's arrival platform (a 5 × 5
    obsidian floor at y 48 around (100, 0) with air above, as
    `EndPlatformFeature.createEndPlatform` makes it), facing west; inside the
    End, a player who has not seen the credits sees them first, and then (or
    one who has) returns to the overworld's spawn.

  Blocks a new portal or platform replaces drop nothing yet (vanilla drops
  their loot); eyes thrown into the air (towards a stronghold) are not handled.
  """
  alias Valimc.Portal.{Access, Blocks}
  alias Valimc.Registry.Blocks, as: Registry

  @spawn {100, 50, 0}
  @portal Registry.default_state("end_portal")

  @doc "Whether a state is an end portal frame, and whether it holds an eye."
  def frame?(state), do: Registry.block_id(state) == Registry.id("end_portal_frame")
  def eye?(state), do: frame?(state) and property(state, "eye") == "true"

  defp property(state, name), do: state |> Registry.properties() |> Map.new() |> Map.fetch!(name)

  @doc "The frame state with an eye (`HAS_EYE` set)."
  def with_eye(state),
    do:
      Registry.state("end_portal_frame", %{"facing" => property(state, "facing"), "eye" => "true"})

  @doc """
  The 3 × 3 opening a complete frame around it makes portal, found as
  vanilla's `BlockPattern.find` does from `position` (a frame), or nil.
  """
  def opening(read, {px, py, pz}) do
    Enum.find_value(
      for(z <- pz..(pz + 4), y <- py..(py + 4), x <- px..(px + 4), do: {x, y, z}),
      fn corner -> if ring?(read, corner), do: interior(corner) end
    )
  end

  # The pattern's one matching orientation: its front top left at the ring's
  # largest X and Z corner, rows running north and columns west from it.
  defp ring?(read, {mx, y, mz}) do
    sides = [
      # The south side's frames face north, the north side's south.
      {for(x <- (mx - 3)..(mx - 1), do: {x, y, mz}), "north"},
      {for(x <- (mx - 3)..(mx - 1), do: {x, y, mz - 4}), "south"},
      # The east side's face west, the west side's east.
      {for(z <- (mz - 3)..(mz - 1), do: {mx, y, z}), "west"},
      {for(z <- (mz - 3)..(mz - 1), do: {mx - 4, y, z}), "east"}
    ]

    Enum.all?(sides, fn {cells, facing} ->
      Enum.all?(cells, fn cell ->
        state = read.(cell)
        eye?(state) and property(state, "facing") == facing
      end)
    end)
  end

  defp interior({mx, y, mz}),
    do: for(x <- 0..2, z <- 0..2, do: {mx - 3 + x, y, mz - 3 + z})

  @doc "End portal blocks for an opening."
  def portal_edits(cells), do: Enum.map(cells, &{&1, @portal})

  @doc """
  Where an end portal leads from the caller's dimension: `{:ok, target}`,
  `{:credits, target}` (the credits first; then the target) or `{:error, reason}`.
  """
  def destination(entry) do
    case Valimc.Dimension.current() do
      :the_end ->
        target = respawn_target()
        if Map.get(entry, :seen_credits, false), do: {:ok, target}, else: {:credits, target}

      _ ->
        Valimc.Dimension.within(:the_end, fn ->
          {x, y, z} = @spawn
          read = Access.reader()

          with :ok <- Access.commit(platform(read, {x, y - 1, z})) do
            {:ok,
             %{
               dimension: :the_end,
               x: x + 0.5,
               # A player arrives a block lower, on the platform's floor.
               y: y - 1.0,
               z: z + 0.5,
               yaw: 90.0,
               pitch: entry.pitch,
               velocity: entry.velocity,
               portal: true
             }}
          end
        end)
    end
  end

  @doc "The block square (`{x0, z0, x1, z1}`) the End's arrival platform covers."
  def platform_area do
    {x, _y, z} = @spawn
    {x - 2, z - 2, x + 2, z + 2}
  end

  @doc "`EndPlatformFeature.createEndPlatform` at `origin`: the blocks it changes, in order."
  def platform(read, {ox, oy, oz}) do
    air = Registry.default_state("air")

    for dz <- -2..2,
        dx <- -2..2,
        dy <- -1..2,
        position = {ox + dx, oy + dy, oz + dz},
        block = if(dy == -1, do: Blocks.obsidian(), else: air),
        Registry.block_id(read.(position)) != Registry.block_id(block),
        do: {position, block}
  end

  @doc "The overworld's spawn, as a respawn without a bed or anchor finds it (VMC-040)."
  def respawn_target do
    spawn = Valimc.Dimension.within(:overworld, &Valimc.World.PlayerSpawn.find/0)

    %{
      dimension: :overworld,
      x: spawn.x,
      y: spawn.y,
      z: spawn.z,
      yaw: spawn.yaw,
      pitch: 0.0,
      velocity: {0.0, 0.0, 0.0},
      portal: true
    }
  end
end
