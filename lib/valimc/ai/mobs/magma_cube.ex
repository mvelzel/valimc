defmodule Valimc.AI.Mobs.MagmaCube do
  @moduledoc """
  A magma cube (VMC-043d, vanilla's `MagmaCube`), a cube
  (`Valimc.AI.Mobs.Cube`): it waits four times as long between hops, jumps
  higher the bigger it is and leaps out of lava, always lit, never a baby.
  Every size hurts what touches it, for its size plus two; its armor is
  three a size and its experience its size. Its sounds are its own, the
  smallest's quieter kinds.
  """
  @behaviour Valimc.AI.Kind

  alias Valimc.AI.Self
  alias Valimc.AI.Mobs.Cube
  alias Valimc.Data.Float32

  @magma_cube "minecraft:magma_cube"

  @impl true
  def types, do: [@magma_cube]

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

  @doc "`setSize`'s own part: attack damage its size, armor three a size."
  def attributes(size),
    do: [{"minecraft:attack_damage", size * 1.0}, {"minecraft:armor", size * 3.0}]

  @doc "`setSize(size, true)` on its mob and data."
  def set_size(mob, data, size), do: Cube.set_size(mob, @magma_cube, data, size, &attributes/1)

  @impl true
  def finalize(%Self{} = self, reason) do
    Cube.finalize(self, reason, &attributes/1)
  end

  @doc "`split`: its halves when it is removed after dying."
  @impl true
  def split(body, position), do: Cube.split(body, position, &attributes/1)

  @doc """
  `jumpFromGround` (a tenth a size more) and `jumpInLiquid` in lava
  (`0.22F + size * 0.05F`), for the kernel.
  """
  @impl true
  def jump(%{data: %{size: size}}) do
    f = &Float32.round/1
    {f.(size * f.(0.1)) * 1.0, f.(f.(0.22) + f.(size * f.(0.05))) * 1.0}
  end

  @impl true
  def move_control(%Self{} = self), do: Cube.move_control(self, &jump_delay/1)

  # `getJumpDelay`: four times a cube's.
  defp jump_delay(self) do
    {delay, self} = Cube.jump_delay(self)
    {delay * 4, self}
  end

  @impl true
  def after_tick(%Self{} = self), do: Cube.after_tick(self, true)

  @doc "`canDealDamage`: every size."
  def deals_damage?(_self), do: true

  @doc "`getAttackDamage`: its attack damage and two."
  def attack_damage(self), do: Float32.round(Cube.attack_damage(self) + 2.0)

  @doc "Its jump sound."
  def jump_sound(_self), do: "minecraft:entity.magma_cube.jump"

  @doc "Its squish on landing, the smallest's own."
  def squish_sound(self),
    do:
      if(Cube.tiny?(self),
        do: "minecraft:entity.magma_cube.squish_small",
        else: "minecraft:entity.magma_cube.squish"
      )

  @impl true
  def sound(body, "hurt_sound"),
    do:
      if(Cube.tiny?(body),
        do: "minecraft:entity.magma_cube.hurt_small",
        else: "minecraft:entity.magma_cube.hurt"
      )

  def sound(body, "death_sound"),
    do:
      if(Cube.tiny?(body),
        do: "minecraft:entity.magma_cube.death_small",
        else: "minecraft:entity.magma_cube.death"
      )

  def sound(_body, _key), do: nil
end
