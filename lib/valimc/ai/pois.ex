defmodule Valimc.AI.Pois do
  @moduledoc """
  Points of interest (VMC-044a1): vanilla's `PoiManager` read from the
  blocks themselves. Each POI type (`village_facts.json`, `VillageOracle
  facts`) names its block states, its tickets and its valid range; a block
  of one of those states is that POI, as vanilla's records follow its
  blocks.

  A POI's taken tickets are the villagers whose home, job site, potential
  job site or meeting point memory names it (`claims/1`), over the group's
  sections (`World.pois`): a claim lives and ends with its villager, so it
  needs no store of its own. Claims made earlier in a tick are in the world
  for the mobs after (`take/2`, `release/2`).

  `sections_to_village/2` is `PoiManager.sectionsToVillage`: the chessboard
  distance in 16-block sections to one holding an occupied POI of the
  `village` tag, at most 6 (7 when none is that near).
  """
  alias Valimc.AI.{Self, Villagers, World}

  @types Map.new(Villagers.poi_facts(), fn {name, t} ->
           {name,
            %{
              states: t["states"],
              max_tickets: t["max_tickets"],
              valid_range: t["valid_range"],
              tags: t["tags"]
            }}
         end)

  @by_state for {name, t} <- @types, state <- t.states, into: %{}, do: {state, name}
  @all_states Map.keys(@by_state) |> MapSet.new()

  @village for {name, t} <- @types, "minecraft:village" in t.tags, into: MapSet.new(), do: name

  @doc "The POI type names."
  def types, do: Map.keys(@types)

  @doc "The facts of POI type `name`."
  def type(name), do: Map.fetch!(@types, name)

  @doc "The POI type of block `state` (`PoiTypes.forState`), or nil."
  def of_state(state), do: Map.get(@by_state, state)

  @doc "Whether POI type `name` has tag `tag`."
  def tagged?(name, tag), do: tag in type(name).tags

  @doc "The block states of the POI types `names`, as a set."
  def states(names), do: names |> Enum.flat_map(&type(&1).states) |> MapSet.new()

  @doc "Every POI state."
  def all_states, do: @all_states

  @doc "The memories whose position claims a POI ticket (`Villager.POI_MEMORIES`)."
  def claiming, do: [:home, :job_site, :potential_job_site, :meeting_point]

  @doc "The POI type at `pos` (`getType`), or nil."
  def type_at(%World{} = world, pos) do
    case World.block(world, pos) do
      nil -> nil
      state -> of_state(state)
    end
  end

  @doc "`PoiRecord.hasSpace` of the POI of `type` at `pos`."
  def space?(%World{pois: claims}, type, pos),
    do: Map.get(claims, pos, 0) < type(type).max_tickets

  @doc "`PoiRecord.isOccupied`."
  def occupied?(%World{pois: claims}, type, pos),
    do: type(type).max_tickets > 0 and Map.get(claims, pos, 0) > 0

  @doc """
  `getInRange(types, center, radius, occupancy)`: the POIs of `types` (a
  list of names) within `radius` of block `center` (a square of chunks,
  then the square and the sphere), in chunk and section order, as `[{type,
  pos}]`. `occupancy` is `:any`, `:has_space` or `:occupied`.
  """
  def in_range(%World{} = world, types, {cx, _, cz} = center, radius, occupancy) do
    states = states(types)
    chunks = Integer.floor_div(radius, 16) + 1
    {ccx, ccz} = {Integer.floor_div(cx, 16), Integer.floor_div(cz, 16)}

    for x <- (ccx - chunks)..(ccx + chunks),
        z <- (ccz - chunks)..(ccz + chunks),
        {pos, state} <- chunk(world, {x, z}, states),
        {px, _, pz} = pos,
        abs(px - cx) <= radius and abs(pz - cz) <= radius,
        dist_sq(pos, center) <= radius * radius,
        type = of_state(state),
        fits?(world, type, pos, occupancy),
        do: {type, pos}
  end

  defp fits?(_world, _type, _pos, :any), do: true
  defp fits?(world, type, pos, :has_space), do: space?(world, type, pos)
  defp fits?(world, type, pos, :occupied), do: occupied?(world, type, pos)

  # A chunk's POI blocks of `states`, by section and then position.
  defp chunk(world, {x, z}, states) do
    {x0, z0} = {x * 16, z * 16}

    world
    |> World.find({x0, world.min_y, z0, x0 + 15, world.max_y, z0 + 15}, states)
    |> Enum.sort_by(fn {{px, py, pz}, _} -> {Integer.floor_div(py, 16), py, pz, px} end)
  end

  @doc "`findAllClosestFirstWithType`: `in_range/5` sorted by distance to `center` (stably)."
  def closest_first(world, types, center, radius, occupancy) do
    world
    |> in_range(types, center, radius, occupancy)
    |> Enum.sort_by(fn {_, pos} -> dist_sq(pos, center) end)
  end

  @doc "`findClosest`: the nearest of `in_range/5`, or nil."
  def closest(world, types, center, radius, occupancy) do
    case closest_first(world, types, center, radius, occupancy) do
      [] -> nil
      [{_, pos} | _] -> pos
    end
  end

  @doc "`BlockPos.distSqr`."
  def dist_sq({ax, ay, az}, {bx, by, bz}),
    do: (ax - bx) * (ax - bx) + (ay - by) * (ay - by) + (az - bz) * (az - bz)

  @doc "`BlockPos.closerToCenterThan(position, distance)`: the block's center within `distance`."
  def near_center?({bx, by, bz}, {x, y, z}, distance) do
    {dx, dy, dz} = {bx + 0.5 - x, by + 0.5 - y, bz + 0.5 - z}
    dx * dx + dy * dy + dz * dz < distance * distance
  end

  ## Tickets

  @doc "`PoiManager.take` of the POI at `pos` by the mob: the world counts it at once."
  def take(%Self{world: world} = self, pos) do
    world = %{world | pois: Map.update(world.pois, pos, 1, &(&1 + 1))}
    %{self | world: world}
  end

  @doc "`PoiManager.release` of the POI at `pos`."
  def release(%Self{world: world} = self, pos) do
    pois =
      case world.pois do
        %{^pos => n} when n > 1 -> %{world.pois | pos => n - 1}
        %{^pos => _} -> Map.delete(world.pois, pos)
        pois -> pois
      end

    %{self | world: %{world | pois: pois}}
  end

  @doc """
  The tickets a list of living villagers' brain memories hold (`%{pos =>
  count}`): each claiming memory names a position (`{dimension, pos}`).
  """
  def claims(memories) do
    Enum.reduce(memories, %{}, fn memories, acc ->
      Enum.reduce(claiming(), acc, fn name, acc ->
        case memories do
          %{^name => {{_dimension, pos}, _ttl}} -> Map.update(acc, pos, 1, &(&1 + 1))
          _ -> acc
        end
      end)
    end)
  end

  @doc """
  The tickets the living villagers of a store's entries (`[{id, entry}]`)
  hold in `dimension`: their minds' memories, or what a record kept.
  """
  def store_claims(entries, dimension) do
    entries
    |> Enum.flat_map(fn
      {_, %{kind: :mob, body: %{type: "minecraft:villager", mob: mob}}} ->
        if Valimc.Entity.Mob.alive?(mob), do: List.wrap(memories(mob.ai)), else: []

      _ ->
        []
    end)
    |> Enum.map(fn memories ->
      for {name, {{^dimension, _}, _}} = m <- memories, name in claiming(), into: %{}, do: m
    end)
    |> claims()
  end

  defp memories(%{brain: %{memories: memories}}), do: memories
  defp memories(%{memories: memories}) when is_map(memories), do: memories
  defp memories(_ai), do: nil

  @doc "Sum claim maps (a section's and its siblings')."
  def merge(claims), do: Enum.reduce(claims, %{}, &Map.merge(&2, &1, fn _, a, b -> a + b end))

  ## Villages

  @doc """
  The 16-block sections holding an occupied village POI (the distance
  tracker's sources), from the world's claims and blocks.
  """
  def village_sections(%World{pois: claims} = world) do
    for {pos, n} <- claims,
        n > 0,
        type = type_at(world, pos),
        type != nil and MapSet.member?(@village, type) and type(type).max_tickets > 0,
        into: MapSet.new(),
        do: section(pos)
  end

  @doc "The 16-block section of a block."
  def section({x, y, z}),
    do: {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}

  @doc "`sectionsToVillage` of a 16-block section (`{sx, sy, sz}`)."
  def sections_to_village(%World{} = world, {sx, sy, sz}) do
    world
    |> villages()
    |> Enum.reduce(7, fn {vx, vy, vz}, best ->
      min(best, Enum.max([abs(vx - sx), abs(vy - sy), abs(vz - sz)]))
    end)
    |> min(7)
  end

  @doc """
  `BehaviorUtils.findSectionClosestToVillage`: of the cube of sections
  `radius` around `center` (`SectionPos.cube`'s order: x, then y, then z),
  the first nearest to a village of those nearer than `center`, else
  `center`.
  """
  def closest_village_section(world, {cx, cy, cz} = center, radius) do
    here = sections_to_village(world, center)

    {best, _} =
      for(
        z <- (cz - radius)..(cz + radius),
        y <- (cy - radius)..(cy + radius),
        x <- (cx - radius)..(cx + radius),
        do: {x, y, z}
      )
      |> Enum.map(&{&1, sections_to_village(world, &1)})
      |> Enum.filter(fn {_, d} -> d < here end)
      |> Enum.min_by(fn {_, d} -> d end, fn -> {center, here} end)

    best
  end

  @doc "`SectionPos.cube(center, radius)` in its order."
  def cube({cx, cy, cz}, radius),
    do:
      for(
        z <- (cz - radius)..(cz + radius),
        y <- (cy - radius)..(cy + radius),
        x <- (cx - radius)..(cx + radius),
        do: {x, y, z}
      )

  @doc "`ServerLevel.isVillage(pos)` (`isCloseToVillage(pos, 1)`)."
  def village?(world, pos), do: sections_to_village(world, section(pos)) <= 1

  defp villages(%World{villages: nil} = world), do: village_sections(world)
  defp villages(%World{villages: villages}), do: villages
end
