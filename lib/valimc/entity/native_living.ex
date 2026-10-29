defmodule Valimc.Entity.NativeLiving do
  @moduledoc """
  The facts native mobs' living rules read beyond the AI's (VMC-081d,
  `valimc_core::mobs::living::facts`), installed in Rust once per VM after
  `Valimc.AI.NativeFacts`: the enchantment definitions
  (`Valimc.Protocol.EnchantmentEffects`), the items' maximum damage, stock
  damage components and attack damage types (`ItemTypes`, `Living.Weapons`),
  the blocks' landing rules (`BlockFacts.landing/1`) and the types that
  breathe under water (`SpawnFacts.water_breather?/1`), each as the decoded
  generated file the Elixir reads.
  """
  alias Valimc.Data.Facts
  alias Valimc.Native

  @doc "Install the facts once per VM (later calls do nothing)."
  def install! do
    Valimc.AI.NativeFacts.install!()

    if not :persistent_term.get({__MODULE__, :installed}, false) do
      {:ok, _} = Native.mob_living_facts_init(facts())
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  @doc "The installer's map: each file's decoded JSON, or the part the rules read."
  def facts do
    blocks = Facts.read!("registry/block_facts.json")

    damage_defaults =
      for {id, item} <- Facts.read!("protocol/item_defaults.json")["items"],
          "minecraft:damage" in item["present"],
          do: String.to_integer(id)

    water_breathers =
      for {name, type} <- Facts.read!("registry/spawn_facts.json")["types"],
          type["water_breather"] == true,
          do: name

    %{
      "enchantments" => Facts.read!("registry/enchantments.json")["enchantments"],
      "items" => Facts.read!("protocol/items.json")["items"],
      "damage_defaults" => damage_defaults,
      "combat_items" => Facts.read!("registry/combat_facts.json")["items"],
      "landing" => Map.put(blocks["columns"]["landing"], "state_count", blocks["state_count"]),
      "water_breathers" => water_breathers
    }
  end
end
