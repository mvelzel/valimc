defmodule Valimc.Entity.Combat do
  @moduledoc """
  The one hurt path for mobs (VMC-037n): `hurt_body/3` is
  `LivingEntity.hurtServer` on a mob body for every kind of damage (melee,
  explosions, falling blocks, its own falls, fire and drowning,
  projectiles), `hurt/3` the same on a body in a store, and `knockback/4`
  the extra knockback an attack adds. A hit outside the mob's cooldown sends
  the damage event, knocks the mob away from the source (unless its type is
  `no_knockback`) and plays the hurt sound; a death sends the death sound
  and event and leaves on the mob what its owner drops (`Mob.death`): its
  loot table's death and a player kill's experience.

  A hit is `%{source, amount}` and optionally `attacker` and `direct` (the
  living entity that caused it and the entity that dealt it, `%{uuid,
  entity_id, player, type, mainhand}`), `position` (where knockback points
  away from; none gives a random direction), `direction` (a projectile's:
  the knockback's `{xd, zd}`, which it is pushed against) and, for an attack,
  `extra_knockback`, `{power, {xd, zd}}` applied when the hit hurts
  (`causeExtraKnockback`).
  """
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.{Body, Mob, Store}
  alias Valimc.Data.Float32
  alias Valimc.Living.{DamageSource, Melee, Weapons}
  alias Valimc.Protocol.CombatPackets

  @doc """
  Hurt body `id` of `store`: `{:ok, store, outcome}` with `outcome.hurt`
  (whether it took the hit), and for a hurt mob `full`, `died`, its health
  before and after. `{:error, :missing_entity}` for no such body.
  """
  def hurt(store, id, hit) do
    case store.entries[id] do
      %{kind: :mob, body: body, entity: entity} ->
        before = body.mob.living.health.value

        case hurt_body(body, entity, hit) do
          :ignored ->
            stirred = stir(body, hit)

            store =
              if stirred == body, do: store, else: Store.change_body(store, id, stirred, [])

            {:ok, store, %{hurt: false}}

          {body, events, outcome} ->
            {:ok, Store.change_body(store, id, body, events),
             Map.merge(outcome, %{
               hurt: true,
               previous: before,
               health: body.mob.living.health.value
             })}
        end

      # A shulker's bullet is broken by any hit (`ShulkerBullet.hurtServer`).
      %{kind: :object, body: %Body{type: "minecraft:shulker_bullet"}, revision: revision} ->
        case Store.remove(store, store.epoch, id, revision) do
          {:ok, store} -> {:ok, store, %{hurt: true}}
          _ -> {:ok, store, %{hurt: false}}
        end

      %{} ->
        {:ok, store, %{hurt: false}}

      nil ->
        {:error, :missing_entity}
    end
  end

  @doc """
  `hurtServer` on a mob `body` at `entity`'s position (nil where only
  `no_knockback` damage comes): `:ignored`, or `{body, events, %{full,
  died}}` with its entity events.
  """
  def hurt_body(%Body{mob: nil}, _entity, _hit), do: :ignored

  def hurt_body(%Body{mob: mob} = body, entity, hit) do
    hook = &Valimc.AI.Mobs.hook(body.type, &1, &2, &3)
    # A family's own take on the hit (a ghast's reflected fireball, VMC-043d).
    hit = hook.(:taken, [body, hit], hit)

    case if(hook.(:ignores?, [body, hit], false),
           do: :ignored,
           else: Mob.hurt(mob, body.type, hit)
         ) do
      :ignored ->
        :ignored

      {:ok, mob, outcome} ->
        source = hit.source
        sounds = sounds(body)
        mob = %{mob | ai: Valimc.AI.hurt(mob.ai, anger(hit, source), DamageSource.type(source))}
        body = %{body | mob: mob}

        {body, events} =
          if outcome.full do
            event =
              {:damage, DamageSource.type(source), entity_id(hit[:attacker]),
               entity_id(hit[:direct]), nil}

            body =
              if DamageSource.is?(source, :no_knockback),
                do: body,
                else:
                  knock(
                    body,
                    Melee.default_knockback(),
                    hit[:direction] || away(entity, hit[:position])
                  )

            {body, [event]}
          else
            {body, []}
          end

        {body, events} =
          cond do
            outcome.died and outcome.full ->
              {body, sound} = sound(body, sounds, "death_sound", false)
              {body, events ++ List.wrap(sound) ++ [{:event, 3}]}

            outcome.died ->
              {body, events ++ [{:event, 3}]}

            outcome.full ->
              {body, sound} = sound(body, sounds, "hurt_sound", true)
              {body, events ++ List.wrap(sound)}

            true ->
              {body, events}
          end

        body =
          case hit[:extra_knockback] do
            {power, direction} when power > 0 -> knock(body, power, direction)
            _ -> body
          end

        body = if outcome.died, do: died(body, hit), else: body
        # What its family does after a hurt (`Valimc.AI.Kind.hurt/2`), with
        # the events it adds (a squid's ink).
        {body, events} =
          case hook.(:hurt, [body, hit], body) do
            {body, more} -> {body, events ++ more}
            body -> {body, events}
          end

        {body, events, outcome}
    end
  end

  @doc """
  A hit of `amount` from damage type `source` on a mob of `type` without an
  attacker (its own falls, fire and drowning, VMC-015i), with its body's
  `data`: `{mob, events, hurt}`.
  """
  def hurt_mob(type, mob, source, amount, data \\ %{}) do
    case hurt_body(%Body{type: type, mob: mob, data: data}, nil, %{
           source: DamageSource.new(source),
           amount: amount
         }) do
      :ignored ->
        {stir(%Body{type: type, mob: mob, data: data}, %{source: DamageSource.new(source)}).mob,
         [], false}

      {body, events, _} ->
        {body.mob, events, true}
    end
  end

  # `hurtServer` restarts the idle time before its cooldown turns a hit away.
  defp stir(%Body{mob: %Mob{ai: %Valimc.AI.Mind{} = mind} = mob} = body, hit) do
    if Mob.stirs?(mob, body.type, hit.source),
      do: %{body | mob: %{mob | ai: %{mind | no_action: 0}}},
      else: body
  end

  defp stir(body, _hit), do: body

  @doc """
  `LivingEntity.knockback(power, xd, zd)` on mob `id` (an attack's extra
  knockback along the attacker's facing): `{:ok, store}`.
  """
  def knockback(store, id, power, direction) do
    case store.entries[id] do
      %{kind: :mob, body: body} ->
        {:ok, Store.change_body(store, id, knock(body, power, direction), [])}

      _ ->
        {:ok, store}
    end
  end

  @doc """
  `Mob.doHurtTarget`'s hit of mob `id` on a target of entity type
  `target_type` (a player for VMC-041a's melee goal): its attack damage after
  its weapon's enchantments, its knockback, the death message's killer, from
  its position. `{:ok, hit}` or `{:error, reason}` for no living mob.
  """
  def mob_hit(store, id, target_type) do
    case store.entries[id] do
      %{kind: :mob, body: body, entity: entity} ->
        if Mob.alive?(body.mob) do
          type = body.type
          mob = body.mob
          weapon = mob.equipment[:mainhand]

          enchantments =
            if weapon, do: Map.get(weapon.components, "minecraft:enchantments", %{}), else: %{}

          target = EntityTypes.id(target_type)
          own = EntityTypes.id(type)
          damage = Float32.round(Mob.value(type, mob, "minecraft:attack_damage"))

          knockback =
            Float32.round(
              Valimc.Protocol.EnchantmentEffects.knockback(
                enchantments,
                target,
                own,
                Float32.round(Mob.value(type, mob, "minecraft:attack_knockback"))
              ) / 2.0
            )

          attacker = %{
            uuid: entity.uuid,
            entity_id: entity.entity_id,
            player: false,
            type: type,
            mainhand: weapon
          }

          {:ok,
           %{
             source: DamageSource.new(Weapons.damage_type(weapon, :mob_attack)),
             amount: Valimc.Protocol.EnchantmentEffects.damage(enchantments, target, own, damage),
             attacker: attacker,
             direct: attacker,
             position: {entity.x, entity.y, entity.z},
             extra_knockback: {knockback, Melee.facing(body.yaw)},
             killer: {:compound, %{"translate" => {:string, EntityTypes.fetch(type).description}}}
           }}
        else
          {:error, :dead_mob}
        end

      _ ->
        {:error, :missing_entity}
    end
  end

  defp knock(body, power, direction) do
    resistance = Mob.value(body.type, body.mob, "minecraft:knockback_resistance")

    %{
      body
      | velocity: Melee.knockback(body.velocity, body.on_ground, power, direction, resistance)
    }
  end

  # `dealDefaultKnockback`: from the source position towards the mob, reversed
  # by `knockback`.
  defp away(_entity, nil), do: {0.0, 0.0}
  defp away(nil, _position), do: {0.0, 0.0}
  defp away(%{x: x, z: z}, {sx, _, sz}), do: {sx - x, sz - z}

  # What angers the mob (`resolveMobResponsibleForDamage`): a living attacker,
  # unless the damage is `no_anger`.
  defp anger(%{attacker: %{uuid: uuid} = attacker}, source) do
    if DamageSource.is?(source, :no_anger),
      do: nil,
      else: {if(attacker.player, do: :player, else: :mob), uuid}
  end

  defp anger(_hit, _source), do: nil

  # `playHurtSound` and the death sound: the mob's voice (`getVoicePitch`, its
  # kind's base: a baby's higher) at its volume, from its own random once it
  # thinks (the hurt sound also restarts its ambient timer,
  # `Mob.playHurtSound`); the store stamps the position.
  defp sound(%Body{mob: %Mob{ai: %Valimc.AI.Mind{} = mind} = mob} = body, sounds, key, hurt) do
    interval = if hurt, do: Valimc.AI.ambient_interval(body.type)
    {pitch, mind} = Valimc.AI.voice(mind, interval, Valimc.AI.Mobs.voice(body.type, body.data))
    {%{body | mob: %{mob | ai: mind}}, sound_event(sounds, key, pitch)}
  end

  defp sound(body, sounds, key, _hurt) do
    base = Valimc.AI.Mobs.voice(body.type, body.data)

    pitch =
      Float32.round(
        Float32.round(Float32.round(:rand.uniform() - :rand.uniform()) * Float32.round(0.2)) +
          base
      )

    {body, sound_event(sounds, key, pitch)}
  end

  defp sound_event(sounds, key, pitch) do
    if sounds[key] do
      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
      {:sound, sounds[key], sounds["sound_source"], sounds["volume"], pitch, seed}
    end
  end

  # The type's hurt and death sounds at its volume (`getSoundVolume`), as
  # its kind changes them (a closed shulker's muffled hurt).
  defp sounds(body) do
    sounds = CombatPackets.mob_sounds(body.type) || %{}
    volume = (Valimc.AI.Facts.mob(body.type) || %{volume: 1.0}).volume

    override = fn sounds, key ->
      case Valimc.AI.Mobs.hook(body.type, :sound, [body, key], nil) do
        nil -> sounds
        # A sound's id (an animal's sound variant's, VMC-043c) or name.
        id when is_integer(id) -> Map.put(sounds, key, id)
        name -> Map.put(sounds, key, Valimc.AI.Facts.sound_id(name))
      end
    end

    sounds |> Map.put("volume", volume) |> override.("hurt_sound") |> override.("death_sound")
  end

  defp entity_id(nil), do: nil
  defp entity_id(%{entity_id: id}), do: id

  @doc """
  A mob `body` that died of `hit` (or of `/kill`, with no hit): it carries
  what its owner drops (`Mob.death`, taken by `Store.take_deaths/1`).
  """
  def died(%Body{mob: %Mob{}} = body, hit) do
    {body, equipment} = equipment_drops(body, hit)
    put_in(body.mob.death, Map.put(death(body, hit), :equipment, equipment))
  end

  @doc false
  def drop_equipment(body, hit), do: equipment_drops(body, hit)

  # `Mob.dropCustomDeathLoot` (VMC-043b): each slot's item by its drop
  # chance (Looting on a player's weapon adds a hundredth a level), from the
  # mob's random; only a player's kill drops what is not kept unworn, and
  # such an item drops worn. Curses of vanishing never drop.
  defp equipment_drops(%Body{mob: mob} = body, hit) do
    killed_by_player = mob.player_memory > 0
    looting = looting(hit[:attacker])

    {mob, drops} =
      Enum.reduce(Keyword.keys(Mob.slots()), {mob, []}, fn slot, {mob, drops} ->
        chance = Mob.drop_chance(mob, slot)
        stack = mob.equipment[slot]

        if chance != 0.0 and stack != nil do
          preserve = chance > 1.0
          chance = if looting > 0, do: Float32.round(chance + 0.01 * looting), else: chance

          if not vanishing?(stack) and (killed_by_player or preserve) do
            {f, mob} = draw(mob, &Valimc.AI.Random.float/1, fn -> :rand.uniform() end)

            if f < chance do
              {stack, mob} = if preserve, do: {stack, mob}, else: worn(mob, stack)
              {%{mob | equipment: Map.delete(mob.equipment, slot)}, [stack | drops]}
            else
              {mob, drops}
            end
          else
            {mob, drops}
          end
        else
          {mob, drops}
        end
      end)

    {%{body | mob: mob}, Enum.reverse(drops)}
  end

  defp looting(%{player: true, mainhand: %{components: components}}),
    do: Map.get(Map.get(components, "minecraft:enchantments", %{}), "minecraft:looting", 0)

  defp looting(_attacker), do: 0

  defp vanishing?(stack),
    do:
      Map.has_key?(
        Map.get(stack.components, "minecraft:enchantments", %{}),
        "minecraft:vanishing_curse"
      )

  # A damageable item that drops off a dead mob is badly worn.
  defp worn(mob, stack) do
    max =
      Map.get(stack.components, "minecraft:max_damage") ||
        Valimc.Protocol.ItemTypes.item(stack.item_id)["max_damage"]

    if is_integer(max) and max > 0 and not Map.has_key?(stack.components, "minecraft:unbreakable") do
      {inner, mob} =
        draw(mob, &Valimc.AI.Random.int(&1, max(max - 3, 1)), fn ->
          :rand.uniform(max(max - 3, 1)) - 1
        end)

      {outer, mob} =
        draw(mob, &Valimc.AI.Random.int(&1, 1 + inner), fn -> :rand.uniform(1 + inner) - 1 end)

      {%{stack | components: Map.put(stack.components, "minecraft:damage", max - outer)}, mob}
    else
      {stack, mob}
    end
  end

  defp draw(%Mob{ai: %Valimc.AI.Mind{random: random} = mind} = mob, fun, _fallback) do
    {value, random} = fun.(random)
    {value, %{mob | ai: %{mind | random: random}}}
  end

  defp draw(mob, _fun, fallback), do: {fallback.(), mob}

  # What the owner drops for a death (`dropAllDeathLoot`): the loot table's
  # death and the experience of a player kill (`dropExperience`).
  defp death(body, hit) do
    mob = body.mob
    facts = EntityTypes.fetch(body.type)
    player_kill = mob.player_memory > 0

    %{
      type: body.type,
      loot_table: facts.loot_table,
      loot: %{
        on_fire: mob.living.fire_ticks > 0 and not facts.fire_immune,
        baby: baby?(body),
        vehicle: nil,
        killed_by_player: player_kill,
        attacker: mainhand(hit[:attacker]),
        direct_attacker: mainhand(hit[:direct]),
        attacker_type: entity_type(hit[:attacker]),
        direct_attacker_type: entity_type(hit[:direct]),
        properties: Valimc.Entity.Animal.properties(body),
        source: source_info(hit)
      },
      experience: if(player_kill and not baby?(body), do: experience(body), else: 0)
    }
  end

  # The killing damage as loot reads it (`damage_source_properties`): its
  # type's tags and its direct and source entities' types.
  defp source_info(hit) do
    direct = hit[:direct]
    attacker = hit[:attacker]

    %{
      tags: Valimc.Protocol.DamageTypes.tags_of(DamageSource.type(hit.source)),
      direct: direct && direct.type,
      source: attacker && attacker.type,
      is_direct: direct != nil and attacker != nil and direct.uuid == attacker.uuid
    }
  end

  # `AgeableMob.isBaby`: a baby drops neither loot nor experience.
  defp baby?(%Body{data: %{age: age}}), do: age < 0
  defp baby?(_body), do: false

  defp mainhand(%{mainhand: stack}), do: stack
  defp mainhand(_), do: :none

  defp entity_type(%{player: true}), do: "minecraft:player"
  defp entity_type(%{type: type}), do: type
  defp entity_type(_), do: nil

  # `Mob.getBaseExperienceReward`: the type's reward and, for a mob that has
  # one, one to three for each equipped hand or armor item; an animal's is
  # one to three (`Animal.getBaseExperienceReward`), from its own random.
  defp experience(body) do
    cond do
      # A chicken jockey's chicken (VMC-043b).
      match?(%{type: "minecraft:chicken", data: %{jockey: true}}, body) ->
        10

      CombatPackets.mob_sounds(body.type)["animal"] ->
        case body.mob.ai do
          %Valimc.AI.Mind{random: random} ->
            {n, _} = Valimc.AI.Random.int(random, 3)
            1 + n

          _ ->
            :rand.uniform(3)
        end

      true ->
        reward(body)
    end
  end

  # A baby zombie's reward is two and a half times an adult's (VMC-043b);
  # equipment it would not lose unworn adds to it.
  defp reward(body) do
    case Weapons.experience(body.type) do
      0 ->
        0

      reward ->
        reward = if match?(%{data: %{baby: true}}, body), do: trunc(reward * 2.5), else: reward

        reward +
          Enum.sum(
            for {slot, _stack} <- body.mob.equipment,
                slot in [:mainhand, :offhand, :feet, :legs, :chest, :head],
                Mob.drop_chance(body.mob, slot) <= 1.0,
                do: :rand.uniform(3)
          )
    end
  end
end
