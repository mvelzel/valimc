defmodule Valimc.World.CatSpawner do
  @moduledoc """
  `CatSpawner` (VMC-044a3), the overworld's, run by a group after its
  natural spawns while mobs spawn: every 1200 ticks a random player of the
  group (`getRandomPlayer`) and a spot 8 to 31 blocks from it on both axes
  at its height, from the group's level random. Where the chunks within ten blocks are loaded and a cat may stand
  (`isSpawnPositionOk`), a cat spawns there near a village (within two
  sections) with more than four occupied homes within 48 blocks and fewer
  than five cats around, or in a swamp hut (`cats_spawn_in`) with no cat
  near, which keeps it for good. It finalizes as a natural spawn.

  Vanilla's countdown and player are the level's; here each group with
  players counts down on its own, so players standing in several groups get
  a try in each.
  """
  alias Valimc.AI.Pois
  alias Valimc.Data.{EntityTypes, Grid, JavaRandom}
  alias Valimc.Entity.{Body, Store}

  @interval 1200
  @cat "minecraft:cat"
  @home "minecraft:home"
  @huts MapSet.new(
          Valimc.Data.Facts.read!("loot/registries.json")["tags"]["minecraft:worldgen/structure"][
            "minecraft:cats_spawn_in"
          ]
        )

  @doc """
  One tick of the spawner for `group` (`Valimc.World.Spawning.plan/1`'s)
  with the level `random` its natural spawns left: `{countdown, random,
  [{section key, record}]}`.
  """
  def tick(group, random) do
    countdown = Map.get(group.spawning, :cats, 0) - 1

    if countdown > 0 or group.players == [] or group.dimension != :overworld or
         not Valimc.World.GameRules.get(:spawn_mobs) do
      {countdown, random, []}
    else
      {n, random} = JavaRandom.next_int(random, length(group.players))
      {px, py, pz, _, _} = Enum.at(group.players, n)
      {dx, random} = offset(random)
      {dz, random} = offset(random)
      pos = {floor(px) + dx, floor(py), floor(pz) + dz}
      {@interval, random, spawn(group, pos)}
    end
  end

  defp offset(random) do
    {n, random} = JavaRandom.next_int(random, 24)
    {negative, random} = JavaRandom.next_boolean(random)
    {(8 + n) * if(negative, do: -1, else: 1), random}
  end

  defp spawn(group, {x, _, z} = pos) do
    {region, siblings, absent} = Valimc.World.Spawning.stores(group)
    kind = EntityTypes.id(@cat)

    case Valimc.Native.spawn_position_ok(
           region,
           siblings,
           absent,
           group.environment,
           kind,
           pos,
           10
         ) do
      {:ok, {true, true, _}} ->
        world = world(group)

        cond do
          Pois.sections_to_village(world, Pois.section(pos)) <= 2 ->
            homes = Pois.in_range(world, [@home], pos, 48, :occupied)

            if length(homes) > 4 and cats(group, pos, 48, 8) < 5,
              do: [cat(pos, false)],
              else: []

          Valimc.AI.World.in_structure?(world, pos, @huts) ->
            if cats(group, pos, 16, 8) == 0, do: [cat(pos, true)], else: []

          true ->
            []
        end

      _ ->
        []
    end
    |> Enum.map(&{Grid.region_key(Grid.chunk_key(x, z)), &1})
  end

  # What the spawner reads of the group: its sections' POI tickets and kept
  # structure starts, and the published blocks.
  defp world(group) do
    view = Valimc.World.View.new(group.dimension)
    resources = Map.values(group.sections)

    %Valimc.AI.World{
      read: &Valimc.World.View.block(view, &1),
      find: &find(view, &1, &2),
      pois: Pois.merge(for r <- resources, do: r.poi_claims),
      structures: Enum.reduce(resources, %{}, &Map.merge(&2, &1.structures))
    }
  end

  defp find(view, {x0, y0, z0, x1, y1, z1}, states) do
    list = MapSet.to_list(states)

    for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
        cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
        {{x, y, z}, state} <- Valimc.World.View.find(view, {cx, cz}, list),
        x in x0..x1 and y in y0..y1 and z in z0..z1,
        do: {{x, y, z}, state}
  end

  # `getEntitiesOfClass(Cat.class, new AABB(pos).inflate(h, v, h))`.
  defp cats(group, {x, y, z}, h, v) do
    {x0, y0, z0, x1, y1, z1} = {x - h, y - v, z - h, x + 1 + h, y + 1 + v, z + 1 + h}

    for {_, resource} <- group.sections,
        {_, %{kind: :mob, entity: e, body: %{type: @cat}}} <- resource.entities.store.entries,
        e.x > x0 - 0.3 and e.x < x1 + 0.3 and e.y + 0.7 > y0 and e.y < y1 and
          e.z > z0 - 0.3 and e.z < z1 + 0.3,
        reduce: 0,
        do: (n -> n + 1)
  end

  # `spawnCat`: a natural spawn at the spot's bottom centre, facing south.
  defp cat({x, y, z}, persistent) do
    {:ok, body} = Body.spawned(@cat, :natural)
    body = if persistent, do: put_in(body.mob.persistent, true), else: body
    Store.body_record(body, :crypto.strong_rand_bytes(16), {x + 0.5, y * 1.0, z + 0.5})
  end
end
