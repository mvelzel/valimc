defmodule Valimc.World.Portal.Destination do
  @moduledoc """
  Where a player entering a nether portal arrives (VMC-026b2), as vanilla's
  `NetherPortalBlock.getPortalDestination` decides: the other dimension (the
  Nether from the overworld or the End, the overworld from the Nether), the
  position scaled by the dimensions' coordinate scales (8) and clamped to the
  destination's border, the closest portal there (within 16 blocks into the
  Nether, 128 out) or a new one (`Valimc.World.Portal.Forcer`), and the place in it
  matching the player's place in the entry portal.

  `nether/1` runs in a task of the entry dimension; it reads, and may create
  the exit portal, in the destination's.
  """
  alias Valimc.World.Portal.{Access, Forcer}
  alias Valimc.Blocks.PortalBlocks

  @doc """
  The travel target for `entry` (`%{position, entry, pose, yaw, pitch,
  velocity, spectator}`): `{:ok, target}` (a `Valimc.Player.Travel` target),
  `:none` (a spectator with no portal to arrive at) or `{:error, reason}`.
  """
  def nether(entry) do
    {axis, offset} = entry_place(entry)
    {to, approx} = approx(Valimc.World.Dimension.current(), entry.position)

    border =
      Valimc.World.Border.bounds(Valimc.World.Clock.border(Valimc.World.Dimension.name(to)))

    Valimc.World.Dimension.within(to, fn ->
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
      Valimc.World.Dimension.facts(from).coordinate_scale /
        Valimc.World.Dimension.facts(to).coordinate_scale

    border =
      Valimc.World.Border.bounds(Valimc.World.Clock.border(Valimc.World.Dimension.name(to)))

    {to, Forcer.clamp(border, {x * scale, y, z * scale})}
  end

  # The entry portal's rectangle and the player's place in it
  # (`getDimensionTransitionFromExit`).
  defp entry_place(entry) do
    read = Access.reader()
    state = read.(entry.entry)

    case PortalBlocks.portal_axis(state) do
      nil ->
        {:x, {0.5, 0.0, 0.0}}

      axis ->
        rectangle = Forcer.largest_rectangle(entry.entry, axis, 21, :y, 21, &(read.(&1) == state))
        {axis, Forcer.relative(rectangle, axis, entry.position, dimensions(entry))}
    end
  end

  # `getExitPortal`: the closest stored portal block's rectangle, else a new portal.
  defp exit_portal(approx, to_nether, border, axis, spectator) do
    radius = Forcer.radius(to_nether)
    states = [PortalBlocks.portal(:x), PortalBlocks.portal(:z)]
    portals = Access.portal_blocks(Forcer.search_chunks(approx, radius), states)

    case Forcer.closest(portals, approx, radius, border) do
      {:ok, position} ->
        read = Access.reader()
        state = read.(position)
        found = PortalBlocks.portal_axis(state)
        {:ok, Forcer.largest_rectangle(position, found, 21, :y, 21, &(read.(&1) == state))}

      :none when spectator ->
        :none

      :none ->
        {min_y, height} = Valimc.World.Dimension.bounds()
        logical = Valimc.World.Dimension.facts().logical_height

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
  # turned a quarter when the portals' axes differ, with the traveller's motion
  # turned alike (`Relative.DELTA`, `ROTATION`).
  defp transition(
         {{bx, by, bz} = bottom_left, width, height},
         entry_axis,
         {right, up, forward},
         entry,
         to
       ) do
    read = Access.reader()
    axis = PortalBlocks.portal_axis(read.(bottom_left)) || :x
    {w, h} = dimensions(entry)
    rotation = if entry_axis == axis, do: 0.0, else: 90.0
    offset_right = w / 2.0 + (width - w) * right
    offset_up = (height - h) * up
    offset_forward = 0.5 + forward

    {x, z} =
      if axis == :x,
        do: {bx + offset_right, bz + offset_forward},
        else: {bx + offset_forward, bz + offset_right}

    arrival =
      Valimc.World.Portal.Motion.absolute(
        %{position: entry.position, delta: entry.velocity, yaw: entry.yaw, pitch: entry.pitch},
        %{position: {x, by + offset_up, z}, delta: {0.0, 0.0, 0.0}, yaw: rotation, pitch: 0.0},
        Valimc.World.Portal.Motion.portal()
      )

    {ax, ay, az} = arrival.position

    %{
      dimension: to,
      x: ax,
      y: ay,
      z: az,
      yaw: arrival.yaw,
      pitch: arrival.pitch,
      velocity: arrival.delta,
      portal: true
    }
  end

  @doc "A traveller's size: an entity's own (`dimensions`), or a player's pose's."
  def dimensions(%{dimensions: {width, height}}), do: {width, height}

  def dimensions(entry) do
    pose = Map.get(entry, :pose, :standing)
    {:ok, %{"width" => width, "height" => height}} = Valimc.Data.PlayerPose.dimensions(pose)
    {width, height}
  end
end
