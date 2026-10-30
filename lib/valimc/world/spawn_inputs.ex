defmodule Valimc.World.SpawnInputs do
  @moduledoc """
  Natural spawning's resident inputs (VMC-081g2): what each section of a
  group keeps in the group's `MobWorld` for the spawn kernel
  (`Native.mob_world_spawn_set/2`), pushed only where its source changed.

  Per section: its Region resource and native mob section, its simulated
  and absent chunks as masks, the rows and boxes of its own (Elixir) mobs
  and of its other living bodies, its spawner blocks with their saved
  configuration and its kept starts of structures that override spawns. A
  source is compared by identity with the one last pushed, so a section
  whose terms did not change costs a few comparisons; one whose entries
  changed recomputes its rows and pushes them only when they differ.
  """
  alias Valimc.Data.{EntityTypes, Grid}
  alias Valimc.Entity.NativeMobs

  @spawner Valimc.Blocks.BlockEntityTypes.type_named("minecraft:mob_spawner")

  @doc """
  Pushes into `world` what changed in `sections` (`%{key => resource}`)
  since `seen` (what the last sync pushed, nil at first) and drops the
  sections that left; without a `seen` of this world, every section is
  pushed whole and the world keeps no other. Returns the new `seen` and how
  many chunks the sections simulate.
  """
  def sync(world, sections, seen) do
    {reset, seen} =
      case seen do
        %{world: ^world, sections: kept} -> {false, kept}
        _ -> {true, %{}}
      end

    {changes, now, simulated} =
      Enum.reduce(sections, {[], %{}, 0}, fn {key, resource}, {changes, now, n} ->
        {change, kept} = section(key, resource, Map.get(seen, key, %{}))
        changes = if change == %{}, do: changes, else: [{key, change} | changes]
        {changes, Map.put(now, key, kept), n + MapSet.size(resource.tickets.simulated)}
      end)

    changes =
      for(key <- Map.keys(seen), not Map.has_key?(sections, key), do: {key, :drop}) ++ changes

    if reset or changes != [],
      do: :ok = Valimc.Native.mob_world_spawn_set(world, reset, changes)

    {%{world: world, sections: now}, simulated}
  end

  defp section(key, resource, seen) do
    store = resource.entities.store

    ids =
      {resource.blocks.ref, store.entries, resource.tickets.simulated, resource.generation.absent,
       resource.block_entities.entries, resource.structures, native(store)}

    # A section none of whose sources changed costs this comparison.
    case seen do
      %{ids: ^ids} -> {%{}, seen}
      _ -> section(key, resource, seen, ids)
    end
  end

  defp section(key, resource, seen, ids) do
    store = resource.entities.store
    simulated = resource.tickets.simulated
    absent = resource.generation.absent
    entries = store.entries
    block_entities = resource.block_entities.entries

    kept = %{
      ids: ids,
      region: resource.blocks.ref,
      native: native(store),
      simulated: simulated,
      absent: absent,
      entries: entries,
      block_entities: block_entities,
      structures: resource.structures
    }

    change =
      %{}
      |> changed(:region, kept.region, seen, & &1)
      |> changed(:native, kept.native, seen, & &1)
      |> changed(:simulated, simulated, seen, &NativeMobs.simulated_mask(key, &1))
      |> changed(:absent, absent, seen, &NativeMobs.simulated_mask(key, &1))
      |> changed(:structures, kept.structures, seen, &Map.to_list/1)

    # The owner's mobs and bodies: their rows depend on the entries and on
    # which chunks simulate.
    {change, kept} =
      if same?(seen, :entries, entries) and same?(seen, :simulated, simulated) do
        {change, Map.put(kept, :rows, seen.rows)}
      else
        rows = rows(entries, simulated)

        if Map.get(seen, :rows) == rows,
          do: {change, Map.put(kept, :rows, rows)},
          else: {Map.put(change, :elixir, rows), Map.put(kept, :rows, rows)}
      end

    # The spawner blocks, parsed once per compound.
    if same?(seen, :block_entities, block_entities) do
      {change, Map.put(kept, :spawners, seen.spawners)}
    else
      parsed = Map.get(seen, :spawners, {[], %{}})
      spawners = spawners(block_entities, elem(parsed, 1))

      if elem(spawners, 0) == elem(parsed, 0),
        do: {change, Map.put(kept, :spawners, spawners)},
        else: {Map.put(change, :spawners, elem(spawners, 0)), Map.put(kept, :spawners, spawners)}
    end
  end

  defp same?(seen, field, value), do: Map.has_key?(seen, field) and Map.get(seen, field) === value

  defp changed(change, field, value, seen, push) do
    if same?(seen, field, value), do: change, else: Map.put(change, field, push.(value))
  end

  defp native(%{native: %{ref: ref}}), do: ref
  defp native(_store), do: nil

  @doc """
  The rows of a section's own mobs (`{id, type, {x, y, z}, flags, idle,
  lived}`, flags 1 persistent or from a bucket, 2 alive in a simulated
  chunk) and the boxes of its living bodies other than native mobs.
  """
  def rows(entries, simulated) do
    Enum.reduce(entries, {[], []}, fn
      # A native mob (VMC-081d): its section's census counts it.
      {_, %{native: ref}}, acc when ref != nil ->
        acc

      {id, %{kind: :mob, entity: e, body: %{type: type, mob: mob}} = entry}, {mobs, bodies} ->
        alive = Valimc.Entity.Mob.alive?(mob)

        flags =
          if(mob.persistent or Map.get(entry.body.data, :from_bucket, false), do: 1, else: 0) +
            if(alive and MapSet.member?(simulated, Grid.chunk_key(e.x, e.z)), do: 2, else: 0)

        row =
          {id, EntityTypes.id(type), {e.x, e.y, e.z}, flags, Map.get(entry, :idle, 0),
           Map.get(entry, :lived, 0)}

        {[row | mobs], [box(type, e) | bodies]}

      {_, %{kind: :object, entity: e, body: %{type: type}}}, {mobs, bodies} ->
        {mobs, [box(type, e) | bodies]}

      _, acc ->
        acc
    end)
  end

  defp box(type, %{x: x, y: y, z: z}) do
    %{width: w, height: h} = EntityTypes.fetch(type)
    {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}
  end

  # A section's spawner blocks as the kernel keeps them, by position, with
  # the compounds already parsed (`position => {nbt, pushed}`).
  defp spawners(block_entities, parsed) do
    {list, cache} =
      for {position, %{type: @spawner, nbt: nbt}} <- block_entities,
          reduce: {[], %{}} do
        {list, cache} ->
          entry =
            case parsed do
              %{^position => {^nbt, _} = entry} -> entry
              _ -> {nbt, spawner(position, nbt)}
            end

          case entry do
            {_, nil} -> {list, cache}
            {_, pushed} -> {[pushed | list], Map.put(cache, position, entry)}
          end
      end

    {Enum.sort_by(list, & &1.position), cache}
  end

  # `BaseSpawner.load` of the parts the kernel models: the type its spawn
  # data names (if ValiMC knows it), its delays, count and ranges; `stamp`
  # tells one compound from another.
  defp spawner(position, nbt) do
    case Valimc.Data.NBT.read(nbt) do
      {:ok, {:compound, fields}} ->
        short = fn name, default ->
          case fields[name] do
            {type, v} when type in [:short, :int] -> v
            _ -> default
          end
        end

        %{
          position: position,
          stamp: :erlang.phash2(nbt),
          delay: short.("Delay", 20),
          kind: kind(fields["SpawnData"]),
          min_delay: short.("MinSpawnDelay", 200),
          max_delay: short.("MaxSpawnDelay", 800),
          count: short.("SpawnCount", 4),
          max_nearby: short.("MaxNearbyEntities", 6),
          player_range: short.("RequiredPlayerRange", 16),
          spawn_range: short.("SpawnRange", 4)
        }

      _ ->
        nil
    end
  end

  defp kind({:compound, %{"entity" => {:compound, %{"id" => {:string, id}}}}}) do
    if EntityTypes.fetch(id), do: EntityTypes.id(id)
  end

  defp kind(_data), do: nil
end
