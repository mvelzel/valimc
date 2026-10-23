defmodule Valimc.Player.Attack do
  @moduledoc """
  A player's melee (VMC-037n), run in the group hosting the player:

  - the attack strength ticker (`Player.tick`): it counts ticks and starts
    over when the main hand's item changes, and on a swing (`punch`,
    `handlePunch`, which also shows the swing to others);
  - an attack (`handleAttack`, then `Player.attack`) on a body in reach that
    this group owns: the strength-scaled damage with the weapon's enchantment
    bonus, criticals, sprint knockback, the sweep around a sword's target,
    the weapon's wear, food exhaustion, and vanilla's sounds, critical hit
    animations and damage indicator particles. The hit goes through the one
    hurt path for bodies (`Region.hurt_entity/3`).

  Not attacked yet: bodies in another group (only while two groups merge)
  and other players (PvP, a follow-up). Effects on attack damage and speed
  (Strength, Weakness, Haste, Mining Fatigue) and post-attack enchantment
  effects (Fire Aspect, Bane of Arthropods' slowness) are VMC-037's.
  """
  alias Valimc.Data.{EntityTypes, Float32, Grid}
  alias Valimc.Living.{Attributes, DamageSource, Durability, Melee, Weapons}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{CreativeInventory, Input, Movement, Vitals}
  alias Valimc.Protocol.{CombatPackets, EnchantmentEffects, EntityPackets, ItemStack, Wire}
  alias Valimc.World
  alias Valimc.World.Region
  import Valimc.Protocol.Codec, only: [send_packets: 2, reject: 2]

  defstruct ticker: 0, mainhand: nil

  @player EntityTypes.id("minecraft:player")
  @blindness Valimc.Data.EffectTypes.id("blindness")
  # `#redirectable_projectile` (VMC-037o): an attack turns it back.
  @redirectable ["minecraft:fireball", "minecraft:wind_charge", "minecraft:breeze_wind_charge"]
  # `EntityEvent` of a main-hand item breaking.
  @mainhand_break 47

  @doc "One player tick of the attack strength ticker (`Player.tick`)."
  def tick(%{attack: %__MODULE__{} = attack} = state) do
    current = Inventory.held(state.inventory, :main)
    ticker = attack.ticker + 1
    ticker = if item(attack.mainhand) != item(current), do: 0, else: ticker
    %{state | attack: %{attack | ticker: ticker, mainhand: current}}
  end

  def tick(state), do: state

  defp item(nil), do: nil
  defp item(%ItemStack{item_id: id}), do: id

  @doc "`punch` (`handlePunch`): the main-hand swing, shown to others; strength starts over."
  def punch(%{attack: %__MODULE__{} = attack} = state) do
    Movement.broadcast_player_packet(state, EntityPackets.animate(state.player.entity_id, 0))
    %{state | attack: %{attack | ticker: 0}}
  end

  def punch(state), do: state

  @doc "`attack` (`handleAttack`): the entity of network id in the payload."
  def attack(state, payload) do
    {id, <<>>} = Wire.take_varint(payload)

    cond do
      state.life_stage != :alive or state.player.game_mode.current == :spectator or
          not Input.loaded?(state.player.input) ->
        state

      true ->
        case target(state, id) do
          {:ok, %{type: type} = view, owner} when type in @redirectable ->
            deflect(state, view, owner)

          # A fence knot breaks (`skipAttackInteraction`: no attack follows).
          {:ok, %{type: "minecraft:leash_knot"} = view, owner} ->
            Region.hurt_entity(owner, view.uuid, %{knot: true})
            state

          {:ok, view, owner} ->
            strike(state, view, owner)

          :invalid ->
            reject(
              state,
              Valimc.Text.translatable("multiplayer.disconnect.invalid_entity_attacked")
            )

          :none ->
            state
        end
    end
  end

  @doc """
  The body of network id `id` in reach and owned by this group:
  `{:ok, view, owner}`, `:invalid` for an item or orb (vanilla disconnects an
  attack on them), else `:none`.
  """
  def target(state, id) do
    %{x: x, z: z, dimension: dimension} = player = state.player
    {cx, cz} = Grid.chunk_key(x, z)
    chunks = for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}
    sections = MapSet.new(chunks, &Grid.section(dimension, &1))
    {views, _} = World.visible_entities(sections, chunks)

    with %{} = view <- views[id] || :none,
         true <- in_reach?(player, view) || :none,
         true <- view.kind not in [:item, :orb] || :invalid,
         {:ok, owner} <- owner_of(dimension, view) do
      {:ok, view, owner}
    else
      {:error, _} -> :none
      other -> other
    end
  end

  # `isWithinAttackRange(item, box, 3.0)`: the eye within the entity
  # interaction range of the box, plus the buffer.
  defp in_reach?(player, view) do
    {ex, ey, ez} = Valimc.Living.Interaction.eye(player)
    {x0, y0, z0, x1, y1, z1} = box(view)
    dx = max(max(x0 - ex, ex - x1), 0.0)
    dy = max(max(y0 - ey, ey - y1), 0.0)
    dz = max(max(z0 - ez, ez - z1), 0.0)
    range = Valimc.Living.Interaction.entity_range(player.game_mode.current) + 3.0
    :math.sqrt(dx * dx + dy * dy + dz * dz) <= range
  end

  # A fence knot's entity stands at its block's corner, its box at the
  # block's centre (VMC-043c3).
  defp box(%{at: {x, y, z}, type: "minecraft:leash_knot"}),
    do: {x + 0.3125, y + 0.375, z + 0.3125, x + 0.6875, y + 0.875, z + 0.6875}

  defp box(%{at: {x, y, z}} = view) do
    type =
      Map.get(view, :type) ||
        if(view.kind == :item, do: "minecraft:item", else: "minecraft:experience_orb")

    case EntityTypes.fetch(type) do
      %{width: w, height: h} -> {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}
      nil -> {x, y, z, x, y, z}
    end
  end

  defp owner_of(dimension, view) do
    case World.existing_owner(Grid.section(dimension, Grid.region_key(view.chunk), :section)) do
      {:ok, {pid, _} = owner} when pid == self() -> {:ok, owner}
      _ -> {:error, :not_local}
    end
  end

  # `Player.deflectProjectile` (VMC-037o): the projectile flies along the
  # player's look at its original speed, now the player's, and the attack
  # strength starts over.
  defp deflect(state, view, owner) do
    player = state.player
    me = %{uuid: player.uuid, id: player.entity_id, player: true}
    look = Valimc.Player.Projectiles.look(player)

    case Region.deflect_projectile(owner, view.uuid, look, me) do
      :ok ->
        sound(
          %{state | attack: %{state.attack | ticker: 0}},
          "minecraft:entity.player.attack.nodamage"
        )

      _ ->
        state
    end
  end

  # `Player.attack` on a body.
  defp strike(state, view, owner) do
    mainhand = Inventory.held(state.inventory, :main)
    ticker = state.attack.ticker
    speed = attribute(mainhand, "minecraft:attack_speed")

    if Melee.too_weak?(Weapons.minimum_charge(mainhand), ticker, speed, 5) do
      state
    else
      do_strike(state, view, owner, mainhand, Melee.strength(ticker, speed))
    end
  end

  defp do_strike(state, view, owner, mainhand, strength) do
    player = state.player
    effects = player.living.effects
    enchantments = enchantments(mainhand)
    target = EntityTypes.id(view.type)
    damage = attribute(mainhand, "minecraft:attack_damage")
    sprinting = Attributes.sprinting?(player.input.shared_flags)
    motion = player.motion
    {:ok, movement} = Attributes.movement_speed(effects, sprinting)

    case Melee.attack(%{
           damage: damage,
           enchanted:
             EnchantmentEffects.damage(enchantments, target, @player, Float32.round(damage)),
           strength: strength,
           sprinting: sprinting,
           critical:
             motion.fall_distance > 0 and not motion.on_ground and
               not Map.has_key?(effects, @blindness) and EntityTypes.living?(view.type) and
               not sprinting,
           sweep:
             motion.on_ground and
               Melee.slow_enough?(motion.known_movement, Float32.round(movement.value)) and
               Weapons.sword?(mainhand)
         }) do
      :none ->
        state

      {:ok, hit} ->
        me = attacker(state, mainhand)
        source = DamageSource.new(Weapons.damage_type(mainhand, :player_attack))

        knockback =
          Float32.round(
            Float32.round(
              EnchantmentEffects.knockback(
                enchantments,
                target,
                @player,
                Float32.round(attribute(mainhand, "minecraft:attack_knockback"))
              ) / 2.0
            ) + if(hit.sprint_knockback, do: 0.5, else: 0.0)
          )

        facing = Melee.facing(player.yaw)

        request = %{
          source: source,
          amount: hit.damage,
          attacker: me,
          direct: me,
          position: {player.x, player.y, player.z},
          extra_knockback: {knockback, facing}
        }

        state =
          if hit.sprint_knockback,
            do: sound(state, "minecraft:entity.player.attack.knockback"),
            else: state

        case Region.hurt_entity(owner, view.uuid, request) do
          {:ok, %{hurt: true} = outcome} ->
            state
            |> sweep(hit, view, me, source, enchantments, strength, facing)
            |> show(effects(hit, true, Float32.round(outcome.previous - outcome.health)), view)
            |> wear(mainhand)
            |> Vitals.apply_effect_action({:exhaust, 0.1})

          _ ->
            show(state, effects(hit, false, 0.0), view)
        end
    end
  end

  # `doSweepAttack`: the living bodies around the target, within 3 blocks of
  # the player, each hurt and knocked back.
  defp sweep(state, %{sweep: false}, _view, _me, _source, _enchantments, _strength, _facing),
    do: state

  defp sweep(state, hit, view, me, source, enchantments, strength, facing) do
    state = sound(state, "minecraft:entity.player.attack.sweep")
    player = state.player

    ratio =
      Attributes.value(
        "minecraft:sweeping_damage_ratio",
        Weapons.player_base("minecraft:sweeping_damage_ratio"),
        for(
          {"minecraft:sweeping_damage_ratio", id, amount, op} <-
            EnchantmentEffects.attribute_modifiers([{:mainhand, enchantments}]),
          do: {id, amount, op}
        )
      )

    base = Melee.sweep_damage(ratio, hit.base)
    {x0, y0, z0, x1, y1, z1} = box(view)
    reach = {x0 - 1.0, y0 - 0.25, z0 - 1.0, x1 + 1.0, y1 + 0.25, z1 + 1.0}
    %{x: x, z: z, dimension: dimension} = player
    {cx, cz} = Grid.chunk_key(x, z)
    chunks = for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}
    {views, _} = World.visible_entities(MapSet.new(chunks, &Grid.section(dimension, &1)), chunks)

    for {_, nearby} <- views,
        nearby.kind == :mob,
        Map.get(nearby, :alive, false),
        nearby.uuid != view.uuid,
        Valimc.Data.Box.intersects?(reach, box(nearby)),
        distance_squared(player, nearby.at) < 9.0,
        {:ok, owner} <- [owner_of(dimension, nearby)] do
      amount =
        Float32.round(
          EnchantmentEffects.damage(enchantments, EntityTypes.id(nearby.type), @player, base) *
            strength
        )

      Region.hurt_entity(owner, nearby.uuid, %{
        source: source,
        amount: amount,
        attacker: me,
        direct: me,
        position: {player.x, player.y, player.z},
        extra_knockback: {Melee.default_knockback(), facing}
      })
    end

    {dx, dz} = {-elem(facing, 0), -elem(facing, 1)}
    # `getY(0.5)`: half the player's height.
    y = player.y + 0.9

    broadcast(
      state,
      CombatPackets.particles(
        "minecraft:sweep_attack",
        {player.x + dx, y, player.z + dz},
        {dx, 0.0, dz},
        0.0,
        0
      )
    )
  end

  @doc """
  What an attack shows after its hit lands (`attackVisualEffects` and
  `damageStatsAndHearts`) or not (`hurt` false): `[{:sound, name} |
  {:animate, action} | {:particles, name, count}]` in vanilla's order, for
  an attack `hit` (`Melee.attack/1`) that took `actual` health. The sprint
  knockback sound before the hit and the sweep's sound and particles are the
  sweep's.
  """
  def effects(_hit, false, _actual), do: [{:sound, "minecraft:entity.player.attack.nodamage"}]

  def effects(hit, true, actual) do
    sound =
      cond do
        hit.critical -> [{:sound, "minecraft:entity.player.attack.crit"}, {:animate, 4}]
        hit.sweep -> []
        hit.full -> [{:sound, "minecraft:entity.player.attack.strong"}]
        true -> [{:sound, "minecraft:entity.player.attack.weak"}]
      end

    magic = if hit.magic > 0.0, do: [{:animate, 5}], else: []

    indicator =
      if actual > 2.0,
        do: [{:particles, "minecraft:damage_indicator", trunc(actual * 0.5)}],
        else: []

    sound ++ magic ++ indicator
  end

  defp show(state, effects, %{at: {x, y, z}} = view) do
    Enum.reduce(effects, state, fn
      {:sound, name}, acc ->
        sound(acc, name)

      {:animate, action}, acc ->
        broadcast(acc, EntityPackets.animate(view.entity_id, action))

      {:particles, name, count}, acc ->
        height = EntityTypes.fetch(view.type).height

        broadcast(
          acc,
          CombatPackets.particles(name, {x, y + height * 0.5, z}, {0.1, 0.0, 0.1}, 0.2, count)
        )
    end)
  end

  # `hurtEnemy` and `postHurtEnemy`: a weapon wears by its wear per attack.
  defp wear(state, mainhand) do
    case Weapons.weapon(mainhand) do
      nil ->
        state

      %{wear: wear} ->
        creative = state.player.game_mode.current == :creative
        {after_weapon, broken} = Durability.hurt_and_break(mainhand, wear, creative)
        slot = 36 + state.inventory.selected

        slots =
          if after_weapon,
            do: Map.put(state.inventory.slots, slot, after_weapon),
            else: Map.delete(state.inventory.slots, slot)

        inventory = %{state.inventory | slots: slots} |> Inventory.advance()
        state = CreativeInventory.resync_inventory(%{state | inventory: inventory})

        if broken,
          do:
            state
            |> sound("minecraft:entity.item.break")
            |> broadcast(EntityPackets.entity_event(state.player.entity_id, @mainhand_break)),
          else: state
    end
  end

  # `playServerSideSound`: at the player, from the players' source.
  defp sound(state, name) do
    %{x: x, y: y, z: z} = state.player
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    broadcast(state, CombatPackets.sound(name, "player", {x, y, z}, 1.0, 1.0, seed))
  end

  # To the player and the players around it.
  defp broadcast(state, packet) do
    Movement.broadcast_player_packet(state, packet)
    send_packets(state, [packet])
    state
  end

  defp attacker(state, mainhand),
    do: %{
      uuid: state.player.uuid,
      entity_id: state.player.entity_id,
      player: true,
      type: "minecraft:player",
      mainhand: mainhand
    }

  # A player's attribute with the main hand's stock modifiers.
  defp attribute(mainhand, name) do
    modifiers =
      for {^name, id, amount, op} <- Weapons.modifiers(mainhand, :mainhand),
          do: {id, amount, op}

    Attributes.value(name, Weapons.player_base(name), modifiers)
  end

  defp enchantments(nil), do: %{}

  defp enchantments(%ItemStack{components: components}),
    do: Map.get(components, "minecraft:enchantments", %{})

  defp distance_squared(%{x: x, y: y, z: z}, {ox, oy, oz}),
    do: (x - ox) * (x - ox) + (y - oy) * (y - oy) + (z - oz) * (z - oz)
end
