defmodule Valimc.World.Portal.Warm do
  @moduledoc """
  Portal destinations admitted ahead of a traveller (VMC-026b2, VMC-026b3).

  A region generates the chunks it is asked for (VMC-075), which takes
  seconds on a loaded host the first time a dimension is visited. A portal's
  destination job would wait for that. So a lit nether portal, an opened end
  portal and a portal process that starts admit the owners of the regions
  their destination will read and give them a `:portal` ticket (300 ticks,
  VMC-077e) over those chunks: the exit portal's search and creation square
  around the scaled position, or the End's arrival platform. Admission starts
  an owner's load and returns, so the load and the generation overlap the time
  before the player steps in (or a survival player's portal ticks).

  This only starts loads and generation; it reads nothing and commits nothing.
  It is best effort: with the worker pool full it is skipped, and the
  destination job then loads the owners and asks for the chunks itself.
  """
  alias Valimc.Data.Grid
  alias Valimc.World.Portal.{Destination, EndPortal}
  alias Valimc.World

  # The exit portal's creation spiral (16) and its frame around the scaled position.
  @reach 18

  @doc """
  Admit, in a background task, the regions the destination of a portal of
  `kind` entered at `position` (in the caller's dimension) will read.
  """
  def start(kind, position) do
    from = Valimc.World.Dimension.current()

    if kind == :nether_portal or (kind == :end_portal and from != :the_end) do
      _ =
        Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
          {dimension, area} = Valimc.World.Dimension.within(from, fn -> area(kind, position) end)
          admit(dimension, area)
        end)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The destination dimension and block square (`{x0, z0, x1, z1}`) of a
  portal of `kind` at `position` in the caller's dimension.
  """
  def area(:nether_portal, position) do
    {to, {x, _y, z}} = Destination.approx(Valimc.World.Dimension.current(), position)
    {to, {floor(x) - @reach, floor(z) - @reach, floor(x) + @reach, floor(z) + @reach}}
  end

  def area(:end_portal, _position), do: {:the_end, EndPortal.platform_area()}

  @doc "The region keys covering a block square."
  def regions({x0, z0, x1, z1}) do
    for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
        cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
        uniq: true,
        do: Grid.region_key({cx, cz})
  end

  defp admit(dimension, {x0, z0, x1, z1} = area) do
    center = Grid.chunk_key(div(x0 + x1, 2), div(z0 + z1, 2))

    chunks =
      for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
          cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
          do: {cx, cz}

    by_region = Enum.group_by(chunks, &Grid.region_key/1)

    for key <- regions(area),
        {:ok, pid} <- [World.region(Grid.section(dimension, key, :section))],
        do: Valimc.World.Region.ticket(pid, key, :portal, center, Map.get(by_region, key, []))
  end
end
