defmodule Valimc.AI.NativeFacts do
  @moduledoc """
  The facts native mob AI reads (VMC-081d, `valimc_core::mobs::facts`),
  installed in Rust once per VM at application start. The core gets the
  generated files the Elixir AI decodes (`ai_facts`, `entity_facts`,
  `hostile_facts`, `animal_facts`, `village_facts`, `combat_facts`, the
  attributes, items, status effects, the block registry, tags, the protocol
  registries, the biomes' climates, the structure tags variants name, the
  block outlines an enderman's ray reads, the potions a witch drinks, the
  consumables a drinking mob reads and the dragon's facts), as decoded JSON,
  and decodes each as its Elixir reader does; the per-state block facts are
  `Valimc.Data.BlockFacts`'s own install.
  """
  alias Valimc.Data.Facts
  alias Valimc.Native
  alias Valimc.Protocol.Data

  @doc "Install the facts once per VM (later calls do nothing)."
  def install! do
    if not :persistent_term.get({__MODULE__, :installed}, false) do
      {:ok, _} = Native.mob_facts_init(facts())
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  @doc "The installer's map: each file's decoded JSON, or the part the AI reads."
  def facts do
    ai = Facts.read!("registry/ai_facts.json")
    entities = Facts.read!("registry/entity_facts.json")
    combat = Facts.read!("registry/combat_facts.json")

    climates =
      for {name, biome} <- Facts.read!("worldgen/biomes.json"),
          do: [
            name,
            biome["temperature"] * 1.0,
            biome["temperature_modifier"] == "frozen",
            biome["has_precipitation"]
          ]

    %{
      "ai" => Map.take(ai, ~w(mobs mob_visibility sounds shulker_look swing_fields path_types)),
      "entities" => Map.take(entities, ~w(types categories fields)),
      "effects" => Facts.read!("protocol/status_effects.json")["effects"],
      "hostile" => Facts.read!("registry/hostile_facts.json"),
      "animal" =>
        Map.put(
          Facts.read!("registry/animal_facts.json"),
          "sheep_mixes",
          Valimc.Entity.Animals.Sheep.mix_table()
        ),
      "village" => Facts.read!("registry/village_facts.json"),
      "combat" =>
        Map.take(
          combat,
          ~w(mobs sounds sound_sources particles damage_types experience items)
        ),
      "attributes" => Facts.read!("protocol/attributes.json"),
      "items" => Facts.read!("protocol/items.json")["items"],
      "blocks" => Valimc.Data.Blocks.native_facts(),
      "tags" => Data.tags(),
      "registries" => Data.registries(),
      "climates" => climates,
      "structure_tags" =>
        Facts.read!("loot/registries.json")["tags"]["minecraft:worldgen/structure"],
      "outlines" => Map.take(Facts.read!("physics/outlines.json"), ~w(palette states offsets)),
      "potions" => Map.take(Facts.read!("protocol/potions.json"), ~w(potions)),
      "food_items" => Facts.read!("protocol/food_items.json")["items"],
      "dragon" =>
        Map.take(
          Facts.read!("registry/dragon_facts.json"),
          ~w(ambient_interval max_head_y_rot graph parts phases)
        )
    }
  end
end
