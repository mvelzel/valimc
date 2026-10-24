defmodule Valimc.Entity.EndCrystal do
  @moduledoc """
  An End crystal's data, placement and damage admission (VMC-045a1).
  Its owner removes it before running an explosion, so it cannot hit itself
  again. Explosion damage removes it without a second explosion.
  """
  alias Valimc.Data.{BlockFacts, Blocks, EntityTypes}
  alias Valimc.Living.DamageSource

  def type, do: "minecraft:end_crystal"
  def data, do: %{beam: nil, bottom: true, invulnerable: false}

  def values(%{data: data}),
    do: [{:crystal_beam, data.beam, nil}, {:crystal_bottom, data.bottom, true}]

  @doc "The crystal's stored SNBT from generation, or its vanilla defaults."
  def from_preserved(nil), do: data()

  def from_preserved(snbt) do
    {{:compound, fields}, _} = Valimc.Text.Snbt.parse_compound(Valimc.Text.Reader.new(snbt))

    beam =
      case fields["beam_target"] do
        {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>} -> {x, y, z}
        _ -> nil
      end

    %{
      beam: beam,
      bottom: fields["ShowBottom"] != {:byte, 0},
      invulnerable: fields["Invulnerable"] == {:byte, 1}
    }
  rescue
    _ -> data()
  end

  @doc "The position of a crystal placed on `base`, or an admission error."
  def placement({x, y, z} = base, read, boxes) do
    above = {x, y + 1, z}
    block = read.(base)
    space = read.(above)

    cond do
      block == nil or Blocks.name(Blocks.block_id(block)) not in ["obsidian", "bedrock"] ->
        {:error, :crystal_base}

      space == nil or not BlockFacts.air?(space) ->
        {:error, :crystal_space}

      Enum.any?(boxes, &intersects?(&1, {x, y + 1, z, x + 1, y + 3, z + 1})) ->
        {:error, :crystal_occupied}

      true ->
        {:ok, {x + 0.5, y + 1.0, z + 0.5}}
    end
  end

  @doc "Whether a hit breaks this crystal (`EndCrystal.hurtServer`)."
  def hurt?(%{data: data}, hit) do
    (not data.invulnerable or DamageSource.is?(hit.source, :bypasses_invulnerability) or
       get_in(hit, [:attacker, :creative]) == true) and
      not (DamageSource.is?(hit.source, :is_fire) and EntityTypes.fetch(type()).fire_immune) and
      not (DamageSource.is?(hit.source, :is_fall) and
             EntityTypes.tag?(type(), "fall_damage_immune")) and
      get_in(hit, [:attacker, :type]) != "minecraft:ender_dragon"
  end

  @doc "Whether breaking it with this hit starts an explosion."
  def explodes?(hit), do: not DamageSource.is?(hit.source, :is_explosion)

  defp intersects?({a, b, c, d, e, f}, {x, y, z, u, v, w}),
    do: a < u and d > x and b < v and e > y and c < w and f > z
end
