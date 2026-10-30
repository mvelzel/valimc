defmodule Valimc.World.Pois do
  @moduledoc """
  Points of interest as a group's spawners read them (VMC-044a1, vanilla's
  `PoiManager`): each POI type (`Valimc.Data.VillageFacts`) names its block
  states, tickets and tags; a block of one of those
  states is that POI. Its taken tickets are those the group's villagers
  claim (each section's `poi_claims`, from its mobs' memories).

  A spawner reads a world `%{read, find, pois, structures}`: the published
  blocks (`read.(cell)`), a finder of the cells of a set of states in a box
  (`find.(box, states)`), the claims by POI and the kept structure starts.
  """
  @min_y -64
  @max_y 319

  @types Valimc.Data.VillageFacts.pois()

  @by_state for {name, t} <- @types, state <- t.states, into: %{}, do: {state, name}
  @village for {name, t} <- @types, "minecraft:village" in t.tags, into: MapSet.new(), do: name

  @doc "The POI type of block `state` (`PoiTypes.forState`), or nil."
  def of_state(state), do: Map.get(@by_state, state)

  @doc "Sum claim maps (a group's sections')."
  def merge(claims), do: Enum.reduce(claims, %{}, &Map.merge(&2, &1, fn _, a, b -> a + b end))

  @doc """
  `getInRange(types, center, radius, occupancy)`: the POIs of `types` (a
  list of names) within `radius` of block `center` (a square of chunks,
  then the square and the sphere), in chunk and section order, as `[{type,
  pos}]`. `occupancy` is `:any` or `:occupied`.
  """
  def in_range(world, types, {cx, _, cz} = center, radius, occupancy) do
    states = types |> Enum.flat_map(&@types[&1].states) |> MapSet.new()
    chunks = Integer.floor_div(radius, 16) + 1
    {ccx, ccz} = {Integer.floor_div(cx, 16), Integer.floor_div(cz, 16)}

    for x <- (ccx - chunks)..(ccx + chunks),
        z <- (ccz - chunks)..(ccz + chunks),
        {pos, state} <- chunk(world, {x, z}, states),
        {px, _, pz} = pos,
        abs(px - cx) <= radius and abs(pz - cz) <= radius,
        dist_sq(pos, center) <= radius * radius,
        type = of_state(state),
        occupancy == :any or occupied?(world, type, pos),
        do: {type, pos}
  end

  # `PoiRecord.isOccupied`.
  defp occupied?(world, type, pos),
    do: @types[type].max_tickets > 0 and Map.get(world.pois, pos, 0) > 0

  # A chunk's POI blocks of `states`, by section and then position.
  defp chunk(world, {x, z}, states) do
    {x0, z0} = {x * 16, z * 16}

    world.find.({x0, @min_y, z0, x0 + 15, @max_y, z0 + 15}, states)
    |> Enum.sort_by(fn {{px, py, pz}, _} -> {Integer.floor_div(py, 16), py, pz, px} end)
  end

  defp dist_sq({ax, ay, az}, {bx, by, bz}),
    do: (ax - bx) * (ax - bx) + (ay - by) * (ay - by) + (az - bz) * (az - bz)

  @doc "The 16-block section of a block."
  def section({x, y, z}),
    do: {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}

  @doc """
  `PoiManager.sectionsToVillage` of a 16-block section (`{sx, sy, sz}`):
  the chessboard distance in sections to one holding an occupied POI of the
  `village` tag, at most 7.
  """
  def sections_to_village(world, {sx, sy, sz}) do
    world
    |> villages()
    |> Enum.reduce(7, fn {vx, vy, vz}, best ->
      min(best, Enum.max([abs(vx - sx), abs(vy - sy), abs(vz - sz)]))
    end)
  end

  # The sections holding an occupied village POI, from the claims and blocks.
  defp villages(world) do
    for {pos, n} <- world.pois,
        n > 0,
        state = world.read.(pos),
        state != nil,
        type = of_state(state),
        type != nil and MapSet.member?(@village, type) and @types[type].max_tickets > 0,
        into: MapSet.new(),
        do: section(pos)
  end

  @doc """
  `getStructureWithPieceAt(pos, structures).isValid()` over the kept
  starts: a piece of a start of one of `names` (a set) holds `position`.
  """
  def in_structure?(world, {x, _, z} = position, names) do
    inside = fn [x0, y0, z0, x1, y1, z1], {px, py, pz} ->
      px in x0..x1 and py in y0..y1 and pz in z0..z1
    end

    world.structures
    |> Map.get({Bitwise.bsr(x, 4), Bitwise.bsr(z, 4)}, [])
    |> Enum.any?(fn {name, _box, pieces} ->
      MapSet.member?(names, name) and Enum.any?(pieces, &inside.(&1, position))
    end)
  end
end
