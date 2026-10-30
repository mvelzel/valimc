defmodule Valimc.Entity.Combat do
  @moduledoc """
  The one hurt path for what a store holds (VMC-037n): `hurt/3` resolves a
  hit on a body of a store (melee, explosions, falling blocks, projectiles)
  and applies it. A mob's hit is its section's (`LivingEntity.hurtServer`,
  VMC-081d): the change carries its new row and events. A shulker bullet
  breaks and an end crystal explodes; other bodies take no damage.
  `mob_hit/3` is a mob's melee hit on a target, from its section.

  A hit is `%{source, amount}` and optionally `attacker` and `direct` (the
  living entity that caused it and the entity that dealt it, `%{uuid,
  entity_id, player, type, mainhand}`), `position` (where knockback points
  away from; none gives a random direction), `direction` (a projectile's:
  the knockback's `{xd, zd}`, which it is pushed against) and, for an attack,
  `extra_knockback`, `{power, {xd, zd}}` applied when the hit hurts
  (`causeExtraKnockback`), and `lift`, a throw up after a hurt.
  """
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Living.DamageSource

  @doc """
  Hurt body `id` of `store`: `{:ok, store, outcome}` with `outcome.hurt`
  (whether it took the hit), and for a hurt mob `full`, `died`, its health
  before and after. `{:error, :missing_entity}` for no such body.
  """
  def hurt(store, id, hit) do
    case store.entries[id] do
      nil ->
        {:error, :missing_entity}

      %{revision: revision} = entry ->
        {change, outcome} = resolve(entry, hit)

        with {:ok, store} <- Store.change_entry(store, id, revision, change),
             do: {:ok, store, outcome}
    end
  end

  @doc """
  Resolve a hit on an authoritative entry once, returning the store change
  and its admission outcome. The owner applies it at the entry's revision;
  siblings project the same result and deliver that fenced change before the
  group cuts its frame. No sound/random draw or hurt is repeated on delivery.
  """
  # A native mob (VMC-081d): its section resolves the hit now; the change
  # carries its new row and events.
  def resolve(%{kind: :mob, native: ref, entity: entity}, hit) when ref != nil do
    case Valimc.Native.mob_section_hurt(ref, entity.entity_id, hit) do
      {:ok, {{true, full, died, previous, health}, events, {position, row}}} ->
        {{:native, position, row, events},
         %{hurt: true, full: full, died: died, previous: previous, health: health}}

      {:ok, {{false, _, _, _, _}, events, {position, row}}} ->
        {{:native, position, row, events}, %{hurt: false}}

      {:error, _} ->
        {:keep, %{hurt: false}}
    end
  end

  # A shulker's bullet is broken by any hit (`ShulkerBullet.hurtServer`).
  def resolve(%{kind: :object, body: %Body{type: "minecraft:shulker_bullet"}, entity: e}, _hit),
    do:
      {:remove,
       %{
         hurt: true,
         previous: 0.0,
         health: 0.0,
         feedback: Valimc.Entity.ShulkerBullet.feedback(:hurt, {e.x, e.y, e.z})
       }}

  def resolve(%{body: %Body{type: "minecraft:end_crystal"} = body, entity: e}, hit) do
    if Valimc.Entity.EndCrystal.hurt?(body, hit) do
      {:remove,
       %{
         hurt: true,
         previous: 0.0,
         health: 0.0,
         crystal: {e.x, e.y, e.z},
         explode: Valimc.Entity.EndCrystal.explodes?(hit)
       }}
    else
      {:keep, %{hurt: false}}
    end
  end

  def resolve(%{}, _hit), do: {:keep, %{hurt: false}}

  @doc """
  `Mob.doHurtTarget`'s hit of mob `id` on a target of entity type
  `target_type` (a player for VMC-041a's melee goal): its attack damage after
  its weapon's enchantments, its knockback, the death message's killer, from
  its position. `{:ok, hit}` or `{:error, reason}` for no living mob.
  """
  def mob_hit(store, id, target_type) do
    case store.entries[id] do
      # A native mob's (VMC-081d), from its section.
      %{kind: :mob, native: ref} when ref != nil ->
        with {:ok, hit} <- Valimc.Native.mob_section_mob_hit(ref, id, target_type),
             do: {:ok, %{hit | source: DamageSource.new(hit.source)}}

      _ ->
        {:error, :missing_entity}
    end
  end
end
