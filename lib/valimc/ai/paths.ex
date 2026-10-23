defmodule Valimc.AI.Paths do
  @moduledoc """
  Vanilla's path search (VMC-041b) as the AI asks for it: a request from a
  mob as its navigation sees it (`request/4`: position, size, footing, step
  height, fall limit, its path type malus and door and fence abilities, the
  targets, `PathNavigation.createPath`'s limits and region) and the search
  over a physics view in Rust (`find/2`, `valimc_core::path`: `PathFinder`
  with the walk, amphibious, swim and fly evaluators).

  A path is `%{nodes, types, index, target, reached}`: the nodes as a tuple
  of `{x, y, z}`, their path types (ordinals) beside them, the next node's
  index, the block it was made for and whether it reaches it
  (`Path.canReach`). A result is `{path | nil, random, chunks}`: the mob's
  random after the search (a small flier's start draws on it) and the
  chunks it read, which an owner checks a deferred result against.
  """
  alias Valimc.AI.{Facts, Self, World}
  alias Valimc.Native

  # `PathType` ordinals the navigation reads.
  @walkable_door 3
  @fire_in_neighbor 13
  @damaging_in_neighbor 15

  @doc "Install the path facts in Rust once per VM."
  def install! do
    if not :persistent_term.get({__MODULE__, :installed}, false) do
      Valimc.Data.BlockFacts.install!()
      :ok = Native.path_facts_init(Facts.path_states(), Facts.path_flags())
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  @doc """
  The searches of `requests` over `cells` (`Valimc.Physics.Cells` of a
  view, or a kernel view), in order. Cost grows with the nodes each may
  visit: past the normal scheduler's budget it runs dirty.
  """
  def find(_cells, []), do: []

  def find(cells, requests) do
    install!()
    units = Enum.reduce(requests, 0, &(&1.max_visited + &2))
    {:ok, results} = Native.dispatch(:path_find, units, [cells, requests])
    Enum.map(results, &decode/1)
  end

  defp decode({nil, random, chunks}), do: {nil, random, chunks}

  defp decode({{nodes, target, reached}, random, chunks}) do
    {positions, types} =
      for <<x::signed-32, y::signed-32, z::signed-32, type <- nodes>>, reduce: {[], []} do
        {ps, ts} -> {[{x, y, z} | ps], [type | ts]}
      end

    path = %{
      nodes: positions |> Enum.reverse() |> List.to_tuple(),
      types: types |> Enum.reverse() |> List.to_tuple(),
      index: 0,
      target: target,
      reached: reached
    }

    {path, random, chunks}
  end

  @doc """
  The request `PathNavigation.createPath(targets, radiusOffset, above,
  reach)` makes for the mob: its region reaches `max(followRange, 16)` and
  the offset around its block (raised one for an entity target).
  """
  def request(%Self{} = self, targets, offset, above, reach) do
    nav = self.mind.navigation
    world = self.world
    follow = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:follow_range")
    length = max(Valimc.Data.Float32.round(follow), 16.0)
    radius = trunc(length + offset)
    {bx, by, bz} = Self.block(self)
    from = if above, do: {bx, by + 1, bz}, else: {bx, by, bz}
    {fx, fy, fz} = from

    %{
      evaluator: nav.evaluator,
      mob: %{
        position: {self.x, self.y, self.z},
        width: self.width,
        height: self.height,
        on_ground: self.on_ground,
        in_water: Self.in_water?(self),
        step: Valimc.Data.Float32.round(step(self)),
        max_fall: max_fall(self),
        fall_distance: self.mob.motion.fall_distance,
        malus: malus(self),
        can_pass_doors: nav.can_pass_doors,
        can_open_doors: nav.can_open_doors,
        can_float: nav.can_float,
        can_walk_over_fences: nav.can_walk_over_fences,
        random: self.mind.random
      },
      targets: targets,
      max_path_length: length,
      reach: reach,
      max_visited: floor(length * 16.0),
      multiplier: 1.0,
      region: {{fx - radius, fy - radius, fz - radius}, {fx + radius, fy + radius, fz + radius}},
      min_y: world.min_y,
      height: world.max_y - world.min_y + 1,
      sea_level: world.sea_level,
      border: world.border
    }
  end

  defp step(self), do: Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:step_height")

  # `Mob.getMaxFallDistance`: three blocks, more for a chasing mob with
  # health to spare.
  defp max_fall(%Self{mind: mind, world: world} = self) do
    if World.entity(world, mind.target) == nil do
      3
    else
      f = &Valimc.Data.Float32.round/1
      health = self.mob.living.health.value
      max = f.(Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:max_health"))
      sacrifice = trunc(f.(health - f.(max * f.(0.33))))
      id = Enum.find_index([:peaceful, :easy, :normal, :hard], &(&1 == world.difficulty))
      sacrifice = max(sacrifice - (3 - id) * 4, 0)
      floor(sacrifice + 3.0)
    end
  end

  @types Facts.path_type_names()

  defp malus(%Self{facts: facts}) do
    for type <- @types, into: <<>>, do: <<Map.fetch!(facts.malus, type)::float-32>>
  end

  @doc "`PathNavigation.canCutCorner` of a node's type."
  def cut_corner?(type),
    do: type not in [@fire_in_neighbor, @damaging_in_neighbor, @walkable_door]
end
