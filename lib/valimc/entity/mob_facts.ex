defmodule Valimc.Entity.MobFacts do
  @moduledoc """
  The facts native mobs read (VMC-081d, `valimc_core::mobs::facts` and
  `mobs::living::facts`), installed in Rust once per VM at application
  start, each as the decoded generated file: `ai_facts`, `entity_facts`,
  `hostile_facts`, `animal_facts`, `village_facts`, `combat_facts`, the
  attributes, items, status effects, the block registry, tags, the protocol
  registries, the biomes' climates, the structure tags variants name, the
  block outlines an enderman's ray reads, the potions a witch drinks, the
  consumables a drinking mob reads and the dragon's facts; for the living
  rules the enchantment definitions, the items' damage and kinetic weapon
  components, the
  blocks' landing rules and the types that breathe under water; the path
  search's per-state columns; the record codec's facts; and the sleep facts
  a villager stands up by. The per-state block facts are
  `Valimc.Data.BlockFacts`'s own install.

  The one fact made here rather than generated is the sheep's dye mixes,
  which come from the crafting rules (`DyeColor.getMixedColor`).
  """
  alias Valimc.Data.{EffectTypes, EntityTypes, Facts}
  alias Valimc.Living.Attributes
  alias Valimc.Native
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes}

  @doc "Install every fact once per VM (later calls do nothing)."
  def install! do
    if not :persistent_term.get({__MODULE__, :installed}, false) do
      Valimc.Data.BlockFacts.install!()
      {:ok, _} = Native.mob_facts_init(ai_facts())
      {:ok, _} = Native.mob_living_facts_init(living_facts())
      ai = Facts.read!("registry/ai_facts.json")

      :ok =
        Native.path_facts_init(
          Base.decode16!(ai["path_type_states"], case: :lower),
          Base.decode16!(ai["path_flags"], case: :lower)
        )

      {:ok, _} = Native.mob_section_install(record_facts())
      {flags, floor_states, floors, beds} = Valimc.Data.SleepFacts.native()
      Native.mob_sleep_install(flags, floor_states, Enum.map(floors, &(&1 && &1 * 1.0)), beds)
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  @doc "The AI facts' installer map: each file's decoded JSON, or the part the AI reads."
  def ai_facts do
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
        Map.put(Facts.read!("registry/animal_facts.json"), "sheep_mixes", sheep_mixes()),
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

  @colors ~w(white orange magenta light_blue yellow lime pink gray light_gray cyan purple blue
             brown green red black)

  # `findColorMixInRecipes`: the dye a crafting grid of two dyes makes, for
  # each pair of colours (nil: none), as `[a, b, mixed]` by colour id.
  defp sheep_mixes do
    dyes = Enum.map(@colors, &ItemTypes.id("minecraft:#{&1}_dye"))

    for {a, i} <- Enum.with_index(dyes), {b, j} <- Enum.with_index(dyes) do
      grid = [%ItemStack{item_id: a}, %ItemStack{item_id: b}, nil, nil]

      mixed =
        case Valimc.Menus.Crafting.result(grid) do
          {:ok, %ItemStack{item_id: id}} -> Enum.find_index(dyes, &(&1 == id))
          _ -> nil
        end

      [i, j, mixed]
    end
  end

  @doc "The living rules' installer map: each file's decoded JSON, or the part the rules read."
  def living_facts do
    blocks = Facts.read!("registry/block_facts.json")

    defaults = Facts.read!("protocol/item_defaults.json")["items"]

    present = fn name ->
      for {id, item} <- defaults, name in item["present"], do: String.to_integer(id)
    end

    %{
      "enchantments" => Facts.read!("registry/enchantments.json")["enchantments"],
      "items" => Facts.read!("protocol/items.json")["items"],
      "damage_defaults" => present.("minecraft:damage"),
      "kinetic_defaults" => present.("minecraft:kinetic_weapon"),
      "combat_items" => Facts.read!("registry/combat_facts.json")["items"],
      "landing" => Map.put(blocks["columns"]["landing"], "state_count", blocks["state_count"]),
      "water_breathers" => Valimc.Data.SpawnFacts.water_breathers()
    }
  end

  @doc """
  The record codec's facts: every living type with its maximum health and
  the keys of a fresh body's family data (`Native.mob_section_fresh/1`).
  """
  def record_facts do
    types =
      for name <- EntityTypes.names(), EntityTypes.living?(name), name != "minecraft:player" do
        {:ok, fresh} = Native.mob_section_fresh(name)

        {name, true, Valimc.Entity.Mob.base(name, %{}, "minecraft:max_health") * 1.0,
         Map.keys(fresh.data)}
      end

    %{
      effect_count: EffectTypes.count(),
      absorption_effect: EffectTypes.id("absorption"),
      max_absorption: Attributes.max_absorption() * 1.0,
      types: types
    }
  end
end
