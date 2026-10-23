defmodule Valimc.AI.Mobs.Slime do
  @moduledoc """
  A slime (VMC-043b6, vanilla's `Slime`), a cube (`Valimc.AI.Mobs.Cube`):
  its attack damage and experience are its size; all but the smallest hurt
  what touches them; never a baby. Its sounds are its own, the smallest's
  quieter kinds.
  """
  @behaviour Valimc.AI.Kind

  alias Valimc.AI.Self
  alias Valimc.AI.Mobs.Cube

  @slime "minecraft:slime"

  @impl true
  def types, do: [@slime]

  @impl true
  def goals(_type), do: Cube.goals()

  @impl true
  def data(_type), do: Cube.data()

  @impl true
  def values(body), do: Cube.values(body)

  @impl true
  def dimensions(body), do: Cube.dimensions(body)

  @impl true
  def volume(body), do: Cube.volume(body)

  @impl true
  def loot_properties(body), do: Cube.loot_properties(body)

  @impl true
  def experience(%{data: %{size: size}}), do: size

  @doc "`setSize`'s own part: attack damage its size."
  def attributes(size), do: [{"minecraft:attack_damage", size * 1.0}]

  @doc "`setSize(size, true)` on its mob and data."
  def set_size(mob, data, size), do: Cube.set_size(mob, @slime, data, size, &attributes/1)

  @impl true
  def finalize(%Self{} = self, reason), do: Cube.finalize(self, reason, &attributes/1)

  @doc "`split`: its halves when it is removed after dying."
  @impl true
  def split(body, position), do: Cube.split(body, position, &attributes/1)

  @doc "`jumpFromGround`: its jump power replaces its vertical motion, no bonus."
  @impl true
  def jump(_body), do: {0.0, nil}

  @impl true
  def move_control(%Self{} = self), do: Cube.move_control(self, &Cube.jump_delay/1)

  @impl true
  def after_tick(%Self{} = self), do: Cube.after_tick(self, deals_damage?(self))

  @doc "`canDealDamage`: all but the smallest."
  def deals_damage?(self), do: not Cube.tiny?(self)

  @doc "`getAttackDamage`."
  def attack_damage(self), do: Cube.attack_damage(self)

  def jump_sound(self), do: small(self, "minecraft:entity.slime.jump")
  def squish_sound(self), do: small(self, "minecraft:entity.slime.squish")

  @impl true
  def sound(body, "hurt_sound"), do: small(body, "minecraft:entity.slime.hurt")
  def sound(body, "death_sound"), do: small(body, "minecraft:entity.slime.death")
  def sound(_body, _key), do: nil

  defp small(body, name), do: if(Cube.tiny?(body), do: name <> "_small", else: name)
end
