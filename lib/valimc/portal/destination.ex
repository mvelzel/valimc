defmodule Valimc.Portal.Destination do
  @moduledoc """
  Where a player entering a nether portal arrives (VMC-026b2), as vanilla's
  `NetherPortalBlock.getPortalDestination` decides: the other dimension (the
  Nether from the overworld or the End, the overworld from the Nether), the
  position scaled by the dimensions' coordinate scales (8) and clamped to the
  destination's border, the closest portal there (within 16 blocks into the
  Nether, 128 out) or a new one (`Valimc.Portal.Forcer`), and the place in it
  matching the player's place in the entry portal.

  `nether/1` runs in a task of the entry dimension; it reads, and may create
  the exit portal, in the destination's.
  """
  alias Valimc.Portal.{Access, Blocks, Forcer}

  @doc """
  The travel target for `entry` (`%{position, entry, pose, yaw, pitch,
  velocity, spectator}`): `{:ok, target}` (a `Valimc.Player.Travel` target),
  `:none` (a spectator with no portal to arrive at) or `{:error, reason}`.
  """
  def nether(entry) do
    {axis, offset} = entry_place(entry)
    {to, approx} = approx(Valimc.Dimension.current(), entry.position)
    border = Valimc.World.Border.bounds(Valimc.World.Clock.border(Valimc.Dimension.name(to)))

    Valimc.Dimension.within(to, fn ->
      with {:ok, rectangle} <-
             exit_portal(approx, to == :the_nether, border, axis, entry.spectator) do
        {:ok, transition(rectangle, axis, offset, entry, to)}
      end
    end)
  end

  @doc """
  The dimension a nether portal in `from` leads to, and `position` scaled by
  the dimensions' coordinate scales and clamped to the destination's border.
  """
  def approx(from, {x, y, z}) do
    to = if from == :the_nether, do: :overworld, else: :the_nether

    scale =
      Valimc.Dimension.facts(from).coordinate_scale / Valimc.Dimension.facts(to).coordinate_scale

    border = Valimc.World.Border.bounds(Valimc.World.Clock.border(Valimc.Dimension.name(to)))
    {to, Forcer.clamp(border, {x * scale, y, z * scale})}
  end

  # The entry portal's rectangle and the player's place in it
  # (`getDimensionTransitionFromExit`).
  defp entry_place(entry) do
    read = Access.reader()
    state = read.(entry.entry)

    case Blocks.portal_axis(state) do
      nil ->
        {:x, {0.5, 0.0, 0.0}}

      axis ->
        rectangle = Forcer.largest_rectangle(entry.entry, axis, 21, :y, 21, &(read.(&1) == state))
        {axis, Forcer.relative(rectangle, axis, entry.position, dimensions(entry.pose))}
    end
  end

  # `getExitPortal`: the closest stored portal block's rectangle, else a new portal.
  defp exit_portal(approx, to_nether, border, axis, spectator) do
    radius = Forcer.radius(to_nether)
    states = [Blocks.portal(:x), Blocks.portal(:z)]
    portals = Access.portal_blocks(Forcer.search_chunks(approx, radius), states)

    case Forcer.closest(portals, approx, radius, border) do
      {:ok, position} ->
        read = Access.reader()
        state = read.(position)
        found = Blocks.portal_axis(state)
        {:ok, Forcer.largest_rectangle(position, found, 21, :y, 21, &(read.(&1) == state))}

      :none when spectator ->
        :none

      :none ->
        {min_y, height} = Valimc.Dimension.bounds()
        logical = Valimc.Dimension.facts().logical_height

        case Forcer.create(
               Access.reader(),
               Access.heights(),
               approx,
               axis,
               {min_y, height, logical},
               border
             ) do
          {:ok, {rectangle, edits}} ->
            with :ok <- Access.commit(edits), do: {:ok, rectangle}

          :error ->
            {:error, :no_room_for_portal}
        end
    end
  end

  # `createDimensionTransition`: the same relative place in the exit portal,
  # turned a quarter when the portals' axes differ, with the player's motion.
  defp transition(
         {{bx, by, bz} = bottom_left, width, height},
         entry_axis,
         {right, up, forward},
         entry,
         to
       ) do
    read = Access.reader()
    axis = Blocks.portal_axis(read.(bottom_left)) || :x
    {w, h} = dimensions(entry.pose)
    rotation = if entry_axis == axis, do: 0.0, else: 90.0
    offset_right = w / 2.0 + (width - w) * right
    offset_up = (height - h) * up
    offset_forward = 0.5 + forward

    {x, z} =
      if axis == :x,
        do: {bx + offset_right, bz + offset_forward},
        else: {bx + offset_forward, bz + offset_right}

    %{
      dimension: to,
      x: x,
      y: by + offset_up,
      z: z,
      yaw: entry.yaw + rotation,
      pitch: entry.pitch,
      velocity: entry.velocity,
      portal: true
    }
  end

  defp dimensions(pose) do
    {:ok, %{"width" => width, "height" => height}} = Valimc.Physics.PlayerPose.dimensions(pose)
    {width, height}
  end
end
