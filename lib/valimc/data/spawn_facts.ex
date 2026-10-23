defmodule Valimc.Data.SpawnFacts do
  @moduledoc """
  What natural spawning reads beyond the block and entity facts (VMC-042a),
  from one generated table (`priv/registry/spawn_facts.json`,
  `NaturalSpawnOracle facts`): every biome's natural spawns (type, weight,
  count provider), spawn costs and creature probability at generation, each
  dimension's monster light test, block light limit, ambient light and
  timeline tracks (the sky light level, the surface slime chance), each
  spawning type's spawn box, the block tag it is immune to, its pack limits,
  whether it is a pathfinder and breathes under water, and per block state
  its `isValidSpawn` kind and the spawn rules' block tests.

  `native/2` assembles the term the spawn kernel installs, joining the
  entity facts (category, size, flags, placement) and the caller's biome
  registry ids and tags.
  """
  use Valimc.Data.Facts, "registry/spawn_facts.json"
  alias Valimc.Data.EntityTypes

  @types @facts["types"]
  @dimensions @facts["dimensions"]

  @doc "Whether a mob of `type` breathes under water (`canBreatheUnderwater`)."
  def water_breather?(type), do: match?(%{"water_breather" => true}, @types[type])

  @doc "A dimension's spawn facts (string keys), or nil."
  def dimension(name), do: @dimensions[name]

  @doc """
  The kernel's facts: `biome_ids` maps biome names to registry ids, `tags`
  biome tag names to lists of ids.
  """
  def native(biome_ids, tags) do
    categories =
      for name <-
            ~w(monster creature ambient axolotls underground_water_creature water_creature water_ambient misc),
          into: %{},
          do: {name, EntityTypes.category(String.to_atom(name))}

    types =
      for {name, spawn} <- @types, facts = EntityTypes.fetch(name), into: %{} do
        {name,
         Map.merge(spawn, %{
           "id" => facts.id,
           "category" => Atom.to_string(facts.category),
           "width" => facts.width,
           "height" => facts.height,
           "fire_immune" => facts.fire_immune,
           "spawn_far" => facts.spawn_far,
           "summonable" => facts.summonable,
           "peaceful" => facts.peaceful,
           "spawn_placement" => facts.spawn_placement && Atom.to_string(facts.spawn_placement),
           "spawn_heightmap" => facts.spawn_heightmap
         })}
      end

    biomes =
      for {name, biome} <- @facts["biomes"],
          into: %{},
          do: {name, Map.put(biome, "id", Map.fetch!(biome_ids, name))}

    %{
      "categories" => categories,
      "types" => types,
      "biomes" => biomes,
      "biome_tags" => tags,
      "dimensions" => @dimensions,
      "states" => @facts["states"]
    }
  end
end
