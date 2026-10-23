defmodule Valimc.Entity.Animals.Variants do
  @moduledoc """
  What cows, pigs and chickens share (VMC-043c): a temperature variant and
  a sound variant, both registry entries the client knows by network id
  (`Cow`, `Pig`, `Chicken`'s `DATA_VARIANT_ID` and `DATA_SOUND_VARIANT_ID`,
  temperate and classic by default), a child taking either parent's variant
  (`getBreedOffspring`'s `nextBoolean`) and sounds from its sound variant,
  a baby's own set where the variant has one.
  """
  alias Valimc.AI.Self
  alias Valimc.Entity.Animal

  @doc "The data of a fresh one."
  def data, do: %{variant: "minecraft:temperate", sound_variant: "minecraft:classic"}

  @doc "Its variant fields (`kind` is `cow`, `pig` or `chicken`)."
  def values(kind, data) do
    variants = "minecraft:#{kind}_variant"
    sounds = "minecraft:#{kind}_sound_variant"

    [
      {:"#{kind}_variant", Animal.variant_id(variants, data.variant),
       Animal.variant_id(variants, "minecraft:temperate")},
      {:"#{kind}_sound_variant", Animal.variant_id(sounds, data.sound_variant),
       Animal.variant_id(sounds, "minecraft:classic")}
    ]
  end

  @doc """
  `finalizeSpawn`'s variants: the biome's (`selectVariantToSpawn`), then a
  random sound variant, both from the level's random.
  """
  def finalize(kind, %Self{} = self) do
    {variant, self} = Animal.pick_variant(self, "minecraft:#{kind}_variant")
    {sound, self} = Animal.pick_random(self, "minecraft:#{kind}_sound_variant")
    %{self | data: %{self.data | variant: variant, sound_variant: sound}}
  end

  @doc "A child's variant: the parent's or the partner's."
  def offspring(%Self{} = self, partner) do
    {mine, self} = Self.boolean(self)
    variant = if mine, do: self.data.variant, else: partner.data.variant
    {%{variant: variant}, self}
  end

  @doc """
  A `kind` animal body's hurt or death sound (`key`: `hurt_sound`,
  `death_sound`): its sound variant's, by id.
  """
  def combat_sound(kind, %{data: data}, key) do
    which = if key == "hurt_sound", do: "hurt", else: "death"
    Animal.sound_id(Animal.sound_set(kind, data)[which])
  end

  @doc "Sound `which` (`ambient`, `hurt`, ...) of its sound variant, a baby's where it has one."
  def sound(kind, %Self{data: data}, which), do: Animal.sound_set(kind, data)[which]
end
