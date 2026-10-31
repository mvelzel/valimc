defmodule Valimc.Player.Projectiles do
  @moduledoc """
  A player's projectiles (VMC-037o), in the session the group hosts:

  - **Throws** (`SnowballItem`, `EggItem`, `EnderpearlItem`,
    `ThrowablePotionItem`): a use throws one from the eyes along the view
    (`shootFromRotation`: power 1.5, a potion 0.5 aimed 20 degrees higher),
    with the player's own motion, the throw's sound, and one item used
    unless the player has infinite materials; an ender pearl then cools down
    for a second.
  - **Bows** (`BowItem`): a use draws the bow while an arrow is at hand
    (held, else the first in the inventory; any in creative); its release
    shoots at `getPowerForTime` of the ticks drawn (nothing under 0.1), three
    times that power, critical at full draw, and wears the bow.
  - **Crossbows** (`CrossbowItem`): a use charges for 25 ticks with its
    three loading sounds and loads an arrow into `charged_projectiles`; the
    next use shoots it at 3.15, critical, without the shooter's motion.
  - **Arrival** of what the world sends back: an ender pearl's landing
    (`ThrownEnderpearl.onHit`: the player teleports there, takes 5 damage,
    and one landing in twenty brings an endermite where the player stood),
    a splash potion's or cloud's effects, and the arrow-hit chime.
  - **Pickup** (`AbstractArrow.playerTouch`): a stuck arrow the player
    touches, once its shake is over, goes into the inventory when its
    pickup rule allows.

  An arrow is drawn from the stack as `useAmmo` draws it: infinite
  materials draw a copy that only creative players pick up. Enchantments on
  bows and crossbows (Power, Punch, Flame, Infinity, Multishot, Piercing,
  Quick Charge) are VMC-037's; tipped arrows fly as plain ones and spectral
  arrows and firework rockets are not shot.
  """
  alias Valimc.Data.{Float32, Grid, PlayerPose}
  alias Valimc.Entity.{Projectile, Store}
  alias Valimc.Living.{DamageSource, Durability, Enchant}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{CreativeInventory, ItemUse, Items, Jobs, Movement, Teleports, Use, Vitals}
  alias Valimc.Protocol.{CombatPackets, ItemStack, ItemTypes, Packets, Wire}
  alias Valimc.World.Region

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @thrown %{
    "minecraft:snowball" => {"minecraft:snowball", "minecraft:entity.snowball.throw", 0.0, 1.5},
    "minecraft:egg" => {"minecraft:egg", "minecraft:entity.egg.throw", 0.0, 1.5},
    "minecraft:ender_pearl" =>
      {"minecraft:ender_pearl", "minecraft:entity.ender_pearl.throw", 0.0, 1.5},
    "minecraft:splash_potion" =>
      {"minecraft:splash_potion", "minecraft:entity.splash_potion.throw", -20.0, 0.5}
  }
  @arrows ["minecraft:arrow", "minecraft:tipped_arrow"]
  @eye "minecraft:eye_of_ender"
  @eye_item "minecraft:ender_eye"
  # `use_cooldown` of an ender pearl: one second.
  @pearl_cooldown 20

  @doc "Whether a use of `stack` is a projectile's (a throw, a bow, a crossbow)."
  def handles?(nil), do: false

  def handles?(%ItemStack{} = stack),
    do: Map.has_key?(@thrown, name(stack)) or weapon(stack) != nil or name(stack) == @eye_item

  defp name(%ItemStack{item_id: id}), do: ItemTypes.item(id)["name"]

  defp weapon(stack) do
    case name(stack) do
      "minecraft:bow" -> :bow
      "minecraft:crossbow" -> :crossbow
      "minecraft:trident" -> :trident
      _ -> nil
    end
  end

  @doc "A use of the projectile item `stack` in `hand`."
  def use(state, hand, stack) do
    case {Map.fetch(@thrown, name(stack)), weapon(stack)} do
      {{:ok, throw}, _} -> throw(state, hand, stack, throw)
      {:error, :bow} -> draw(state, hand, stack, :bow)
      {:error, :crossbow} -> crossbow(state, hand, stack)
      {:error, :trident} -> raise_trident(state, hand, stack)
      {:error, nil} -> eye(state, hand)
    end
  end

  ## Eyes of ender

  # `EnderEyeItem.use` in the air (VMC-026d): nothing at an end portal frame
  # looked at (its use on the block fills it, `Valimc.World.Portal.Items`);
  # otherwise the nearest stronghold (`eye_of_ender_located`) from the
  # player's block is found in a job, and the eye flies there (`eyed/3`).
  defp eye(state, hand) do
    player = state.player
    hit = Valimc.Player.Buckets.aim(player, :none)

    cond do
      Jobs.active?(state.jobs, :eye) ->
        state

      not hit.miss and
          Valimc.World.Portal.EndPortal.frame?(
            Valimc.Player.Buckets.block_at(player.dimension, hit.position)
          ) ->
        state

      true ->
        members = Valimc.Blocks.Loot.structure_tag("minecraft:eye_of_ender_located")
        at = {floor(player.x), floor(player.y), floor(player.z)}
        dimension = player.dimension

        task =
          Task.Supervisor.async_nolink(Valimc.TransferWorkers, fn ->
            Valimc.Worldgen.Locate.nearest(dimension, members, at)
          end)

        {jobs, _job} = Jobs.track(state.jobs, :eye, task, timeout: 60_000, data: %{hand: hand})
        %{state | jobs: jobs}
    end
  rescue
    RuntimeError -> state
  catch
    :exit, _ -> state
  end

  @doc """
  The stronghold an eye's use found (`{:ok, {x, y, z, id}}`; nothing when
  none is, or the search failed): from the player's middle an eye flies
  toward its corner (`signalTo`), with the launch sound, and one eye is used
  unless the player has infinite materials. An eye no longer held is not
  thrown.
  """
  def eyed(state, hand, {:ok, {x, y, z, _id}}) do
    player = state.player

    with %ItemStack{} = stack <- Inventory.held(state.inventory, hand),
         @eye_item <- name(stack),
         {:ok, dimensions} <- PlayerPose.dimensions(Map.get(player, :pose, :standing)) do
      at = {player.x, player.y + Float32.round(dimensions["height"]) * 0.5, player.z}

      body =
        @eye
        |> Projectile.new(nil, stack)
        |> Projectile.signal_to(at, {x * 1.0, y * 1.0, z * 1.0})

      case launch(state, body, at) do
        {:ok, state} ->
          # `Mth.lerp(nextFloat, 0.33F, 0.5F)`.
          low = Float32.round(0.33)
          pitch = Float32.round(low + Float32.round(float() * Float32.round(0.5 - low)))
          play(state, "minecraft:entity.ender_eye.launch", "neutral", 1.0, pitch)
          consume(state, hand)

        :error ->
          state
      end
    else
      _ -> state
    end
  end

  def eyed(state, _hand, _result), do: state

  ## Throws

  defp throw(state, hand, stack, {type, sound, offset, power}) do
    if type == "minecraft:ender_pearl" and cooling?(state) do
      state
    else
      player = state.player
      play(state, sound, "neutral", 0.5, Float32.round(0.4 / Float32.round(float() * 0.4 + 0.8)))

      body =
        type
        |> Projectile.new(owner(player), stack)
        |> Projectile.from_rotation(
          {player.pitch, player.yaw},
          offset,
          power,
          1.0,
          movement(player)
        )

      state =
        case launch(state, body, launch_point(player)) do
          {:ok, state} -> consume(state, hand)
          :error -> state
        end

      if type == "minecraft:ender_pearl",
        do: cool_down(state, "minecraft:ender_pearl"),
        else: state
    end
  end

  # Monotonic time may be negative: no cooldown yet is none, not one until 0.
  defp cooling?(state) do
    case Map.get(state, :pearl_cooldown) do
      nil -> false
      until -> System.monotonic_time(:millisecond) < until
    end
  end

  defp cool_down(state, group) do
    send_packets(state, [
      Packets.packet("cooldown", [Wire.string(group), Wire.varint(@pearl_cooldown)])
    ])

    Map.put(state, :pearl_cooldown, System.monotonic_time(:millisecond) + @pearl_cooldown * 50)
  end

  defp consume(state, hand) do
    if state.inventory.infinite_materials do
      state
    else
      slot = slot(state, hand)
      stack = Inventory.get(state.inventory, slot)
      left = if stack.count > 1, do: %{stack | count: stack.count - 1}, else: nil
      inventory = state.inventory |> Inventory.put(slot, left) |> Inventory.advance()
      CreativeInventory.resync_inventory(%{state | inventory: inventory})
    end
  end

  defp slot(state, :main), do: 36 + state.inventory.selected
  defp slot(_state, :off), do: 45

  ## Bows and crossbows

  defp draw(state, hand, stack, kind) do
    if state.inventory.infinite_materials or ammo(state.inventory, kind) != nil do
      state = %{state | active_use: Use.drawing(stack, hand, kind)}
      ItemUse.publish_item_use(state, Use.start_flags(state.player.use_flags, hand))
    else
      state
    end
  end

  defp crossbow(state, hand, stack) do
    case ItemStack.component(stack, "minecraft:charged_projectiles") do
      [_ | _] = loaded -> shoot_crossbow(state, hand, stack, loaded)
      _ -> draw(state, hand, stack, :crossbow)
    end
  end

  @doc """
  The release of a drawn bow (`BowItem.releaseUsing`): the arrows it draws
  (`draw_ammo/2`) at three times the power of the ticks drawn, spread by its
  enchantments (`ProjectileWeaponItem.shoot`). Any use ends.
  """
  def release(%{active_use: %Use{kind: :bow} = use} = state) do
    bow = Inventory.held(state.inventory, use.hand)
    power = power(Use.elapsed(use))

    state =
      with true <- power >= 0.1,
           %ItemStack{} <- bow,
           {:ok, arrows, inventory} <- draw_ammo(%{state | inventory: state.inventory}, bow) do
        player = state.player
        state = %{state | inventory: inventory}

        # `BowItem.shootProjectile`: along the view turned by the angle.
        aim = fn body, angle, _index, state ->
          body =
            Projectile.from_rotation(
              body,
              {player.pitch, Float32.round(player.yaw + angle)},
              0.0,
              Float32.round(power * 3.0),
              1.0,
              movement(player)
            )

          {body, state}
        end

        state = shoot(state, use.hand, bow, arrows, power == 1.0, nil, aim)

        pitch =
          Float32.round(
            Float32.round(1.0 / Float32.round(float() * 0.4 + 1.2)) + Float32.round(power * 0.5)
          )

        play(state, "minecraft:entity.arrow.shoot", "player", 1.0, pitch)
        CreativeInventory.resync_inventory(state)
      else
        _ -> state
      end

    ItemUse.stop_item_use(state)
  end

  # `TridentItem.releaseUsing` after ten ticks: a throw, or with Riptide in
  # water or rain a launch (VMC-037q).
  def release(%{active_use: %Use{kind: :trident} = use} = state) do
    trident = Inventory.held(state.inventory, use.hand)

    state =
      with true <- Use.elapsed(use) >= 10,
           %ItemStack{} <- trident,
           false <- breaks_next?(trident) do
        riptide = riptide(trident)

        cond do
          riptide <= 0.0 -> throw_trident(state, use.hand, trident)
          wet?(state) -> riptide(state, use.hand, trident, riptide)
          true -> state
        end
      else
        _ -> state
      end

    ItemUse.stop_item_use(state)
  end

  def release(state), do: ItemUse.stop_item_use(state)

  @doc """
  One tick of a Riptide spin (`LivingEntity.checkAutoSpinAttack`, VMC-037q):
  the first living body the player's box meets is attacked with the spin's
  8 and the trident's enchantments, and the spin ends with the player
  thrown back a fifth of its motion.
  """
  def spin(%{spin_attack: %{ticks: ticks} = spin} = state) when ticks > 0 do
    player = state.player

    with {:ok, actor} <- Items.actor(player),
         {_, view} <- spin_target(state, actor.box),
         {:ok, owner} <- Items.owner_of(state, view) do
      levels = Enchant.levels(spin.item)

      me = %{
        uuid: player.uuid,
        entity_id: player.entity_id,
        player: true,
        type: "minecraft:player",
        mainhand: spin.item
      }

      ctx = %{
        this: Enchant.entity(type_id: Valimc.Data.EntityTypes.id(view.type)),
        attacker: Valimc.Player.Enchantments.view(state),
        direct: Valimc.Player.Enchantments.view(state),
        damage: {Valimc.Protocol.DamageTypes.id(:player_attack), true}
      }

      Region.hurt_entity(owner, view.uuid, %{
        source: DamageSource.new(:player_attack),
        amount: Enchant.value(:damage, levels, ctx, spin.damage),
        attacker: me,
        direct: me,
        position: {player.x, player.y, player.z},
        post_attack: true
      })

      {vx, vy, vz} = player.motion.velocity
      motion = %{player.motion | velocity: {vx * -0.2, vy * -0.2, vz * -0.2}}
      %{state | player: %{player | motion: motion}} |> Map.put(:spin_attack, %{spin | ticks: 0})
    else
      _ -> Map.put(state, :spin_attack, %{spin | ticks: ticks - 1})
    end
  end

  def spin(state), do: state

  defp spin_target(state, {x0, y0, z0, x1, y1, z1}) do
    %{x: x, z: z, dimension: dimension} = state.player
    {cx, cz} = Grid.chunk_key(x, z)
    chunks = for dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}

    {views, _} =
      Valimc.World.visible_entities(MapSet.new(chunks, &Grid.section(dimension, &1)), chunks)

    Enum.find(views, fn
      {_, %{kind: :mob, alive: true, at: {mx, my, mz}, type: type}} ->
        %{width: w, height: h} = Valimc.Data.EntityTypes.fetch(type)

        mx + w / 2 > x0 and mx - w / 2 < x1 and my + h > y0 and my < y1 and mz + w / 2 > z0 and
          mz - w / 2 < z1

      _ ->
        false
    end)
  end

  # `TridentItem.use`: raised unless its next wear breaks it, or with Riptide
  # out of water and rain.
  defp raise_trident(state, hand, stack) do
    if breaks_next?(stack) or (riptide(stack) > 0.0 and not wet?(state)) do
      state
    else
      state = %{state | active_use: Use.drawing(stack, hand, :trident)}
      ItemUse.publish_item_use(state, Use.start_flags(state.player.use_flags, hand))
    end
  end

  defp riptide(stack),
    do: Enchant.unconditioned(:trident_spin_attack_strength, Enchant.levels(stack), 0.0)

  # `ItemStack.nextDamageWillBreak`.
  defp breaks_next?(stack) do
    case {ItemStack.component(stack, "minecraft:max_damage"),
          ItemStack.component(stack, "minecraft:damage")} do
      {max, damage} when is_integer(max) and is_integer(damage) ->
        not Map.has_key?(stack.components, "minecraft:unbreakable") and damage >= max - 1

      _ ->
        false
    end
  end

  # `isInWaterOrRain`: in water, or in the rain where it stands.
  defp wet?(state) do
    case Valimc.Player.PoseQuery.run(state.player) do
      {:ok, %{kinetics: kinetics}} -> Map.get(kinetics, :water, false) or kinetics.rain == true
      _ -> false
    end
  end

  # The trident sound of its highest-levelled enchantment that has one, by
  # its level, else the throw's (`TRIDENT_SOUND`).
  defp trident_sound(stack, default) do
    Enchant.trident_sound(Enchant.levels(stack)) || default
  end

  # A throw (`ThrownTrident` from the rotation at 2.5): the trident wears a
  # point and leaves the hand, the thrown one carrying it.
  defp throw_trident(state, hand, trident) do
    player = state.player
    infinite = state.inventory.infinite_materials
    {worn, _} = Durability.hurt_and_break(trident, 1, infinite)
    worn = worn || trident
    slot = slot(state, hand)
    left = if infinite, do: worn, else: nil
    inventory = state.inventory |> Inventory.put(slot, left) |> Inventory.advance()
    state = %{state | inventory: inventory}

    body =
      Projectile.trident(owner(player), %{worn | count: 1})
      |> then(fn body ->
        if infinite, do: %{body | data: %{body.data | pickup: :creative_only}}, else: body
      end)
      |> Projectile.from_rotation({player.pitch, player.yaw}, 0.0, 2.5, 1.0, movement(player))

    at = launch_point(player)

    case launch(state, body, at) do
      {:ok, state} ->
        world_sound(
          state,
          trident_sound(trident, "minecraft:item.trident.throw"),
          "player",
          at,
          1.0,
          1.0
        )

        CreativeInventory.resync_inventory(state)

      :error ->
        state
    end
  end

  # Riptide: the player launches along its look at the enchantment's
  # strength and spins for 20 ticks, hitting what it meets for 8
  # (`startAutoSpinAttack`). Its client launches itself; the server keeps its
  # own motion and the spin.
  defp riptide(state, hand, trident, strength) do
    player = state.player
    infinite = state.inventory.infinite_materials
    {worn, _} = Durability.hurt_and_break(trident, 1, infinite)
    slot = slot(state, hand)
    inventory = state.inventory |> Inventory.put(slot, worn || trident) |> Inventory.advance()
    {lx, ly, lz} = view(player)
    length = :math.sqrt(lx * lx + ly * ly + lz * lz)
    scale = strength / length
    {vx, vy, vz} = player.motion.velocity
    velocity = {vx + lx * scale, vy + ly * scale, vz + lz * scale}

    state =
      %{
        state
        | inventory: inventory,
          player: %{player | motion: %{player.motion | velocity: velocity}}
      }
      |> Map.put(:spin_attack, %{ticks: 20, damage: 8.0, item: worn || trident})

    sound = trident_sound(trident, "minecraft:item.trident.riptide_1")
    state = play(state, sound, "player", 1.0, 1.0)
    CreativeInventory.resync_inventory(state)
  end

  @doc "`BowItem.getPowerForTime`."
  def power(ticks) do
    p = Float32.round(ticks / 20.0)
    min(Float32.round(Float32.round(Float32.round(p * p) + Float32.round(p * 2.0)) / 3.0), 1.0)
  end

  @doc """
  One tick of a charging crossbow (`CrossbowItem.onUseTick`): its loading
  sounds at a fifth and half of the charge, and the arrows loaded once full
  (`draw_ammo/2`). The charge time and the sounds are its enchantments'
  (Quick Charge, VMC-037q).
  """
  def charge(%{active_use: %Use{kind: :crossbow} = use} = state) do
    crossbow = Inventory.held(state.inventory, use.hand)
    levels = Enchant.levels(crossbow)
    progress = Float32.round(Use.elapsed(use) / charge_duration(levels))
    loads = Map.get(use, :sounds, 0)
    {start, mid, finish} = charging_sounds(levels)

    cond do
      progress >= 1.0 and loads < 3 ->
        with %ItemStack{} <- crossbow,
             nil <- ItemStack.component(crossbow, "minecraft:charged_projectiles") |> loaded(),
             {:ok, arrows, inventory} <- draw_ammo(state, crossbow) do
          charged = put_in(crossbow.components["minecraft:charged_projectiles"], arrows)

          inventory =
            inventory |> Inventory.put(slot(state, use.hand), charged) |> Inventory.advance()

          state = CreativeInventory.resync_inventory(%{state | inventory: inventory})
          pitch = Float32.round(Float32.round(1.0 / Float32.round(float() * 0.5 + 1.0)) + 0.2)
          state = if finish, do: play(state, finish, "player", 1.0, pitch), else: state
          %{state | active_use: %{use | sounds: 3}}
        else
          _ -> %{state | active_use: %{use | sounds: 3}}
        end

      progress >= 0.5 and loads < 2 ->
        state = if mid, do: play(state, mid, "player", 0.5, 1.0), else: state
        %{state | active_use: %{use | sounds: 2}}

      progress >= 0.2 and loads < 1 ->
        state = if start, do: play(state, start, "player", 0.5, 1.0), else: state
        %{state | active_use: %{use | sounds: 1}}

      true ->
        state
    end
  end

  def charge(state), do: state

  # `CrossbowItem.getChargeDuration`: 1.25 seconds after Quick Charge.
  defp charge_duration(levels) do
    seconds = max(0.0, Enchant.unconditioned(:crossbow_charge_time, levels, 1.25))
    max(floor(Float32.round(seconds * 20.0)), 1)
  end

  @default_sounds {"minecraft:item.crossbow.loading_start",
                   "minecraft:item.crossbow.loading_middle",
                   "minecraft:item.crossbow.loading_end"}

  defp charging_sounds(levels), do: Enchant.charging_sounds(levels) || @default_sounds

  defp loaded([_ | _]), do: :loaded
  defp loaded(_), do: nil

  # `CrossbowItem.performShooting` of its loaded arrows: along the view
  # turned about the player's up vector by each arrow's angle, at 3.15,
  # critical, with the crossbow's hit sound and a shot sound each.
  defp shoot_crossbow(state, hand, crossbow, loaded) do
    player = state.player
    emptied = put_in(crossbow.components["minecraft:charged_projectiles"], [])

    inventory =
      state.inventory |> Inventory.put(slot(state, hand), emptied) |> Inventory.advance()

    state = %{state | inventory: inventory}

    aim = fn body, angle, index, state ->
      direction = turn(view(player), up(player), angle)
      body = Projectile.shoot(body, direction, 3.15, 1.0)
      {body, play(state, "minecraft:item.crossbow.shoot", "player", 1.0, shot_pitch(index))}
    end

    state
    |> shoot(hand, emptied, loaded, true, "minecraft:item.crossbow.hit", aim)
    |> CreativeInventory.resync_inventory()
  end

  # `CrossbowItem.getShotPitch`.
  defp shot_pitch(0), do: 1.0

  defp shot_pitch(index) do
    decider = if rem(index, 2) == 1, do: Float32.round(0.63), else: Float32.round(0.43)
    Float32.round(Float32.round(1.0 / Float32.round(float() * 0.5 + 1.8)) + decider)
  end

  # `ProjectileWeaponItem.shoot`: each arrow from `weapon`, at its angle in
  # the spread its enchantments give (Multishot's 10 degrees each side),
  # aimed by `aim`; the weapon wears a point each, and a broken weapon
  # shoots no more.
  defp shoot(state, hand, weapon, arrows, crit, sound, aim) do
    levels = Enchant.levels(weapon)

    max_angle =
      max(
        0.0,
        Enchant.value(
          :projectile_spread,
          levels,
          %{this: Valimc.Player.Enchantments.view(state)},
          0.0
        )
      )

    n = length(arrows)
    step = if n == 1, do: 0.0, else: Float32.round(2.0 * max_angle / (n - 1))
    offset = Float32.round(rem(n - 1, 2) * step / 2.0)

    {state, _} =
      arrows
      |> Enum.with_index()
      |> Enum.reduce_while({state, 1.0}, fn {arrow, index}, {state, direction} ->
        angle = Float32.round(offset + direction * div(index + 1, 2) * step)

        body =
          "minecraft:arrow"
          |> Projectile.new(owner(state.player), arrow)
          |> creative_only(arrow)
          |> crit(crit)
          |> Projectile.arm(weapon, arrow)
          |> then(fn body ->
            if sound, do: %{body | data: %{body.data | sound: sound}}, else: body
          end)

        {body, state} = aim.(body, angle, index, state)

        state =
          case launch(state, body, launch_point(state.player)) do
            {:ok, state} -> wear(state, hand)
            :error -> state
          end

        if Inventory.get(state.inventory, slot(state, hand)) == nil,
          do: {:halt, {state, -direction}},
          else: {:cont, {state, -direction}}
      end)

    state
  end

  # `getUpVector(1.0F)`: the view vector of the pitch less 90 degrees.
  defp up(player), do: view(%{player | pitch: Float32.round(player.pitch - 90.0)})

  # `Vector3f.rotate` by the axis-angle quaternion of `degrees` about `axis`.
  defp turn(v, _axis, angle) when angle == 0.0, do: v

  defp turn({vx, vy, vz}, {kx, ky, kz}, degrees) do
    theta = Float32.round(degrees * Float32.round(:math.pi() / 180.0))
    {c, s} = {:math.cos(theta), :math.sin(theta)}
    dot = kx * vx + ky * vy + kz * vz
    {cx, cy, cz} = {ky * vz - kz * vy, kz * vx - kx * vz, kx * vy - ky * vx}

    {Float32.round(vx * c + cx * s + kx * dot * (1 - c)),
     Float32.round(vy * c + cy * s + ky * dot * (1 - c)),
     Float32.round(vz * c + cz * s + kz * dot * (1 - c))}
  end

  @doc "`Entity.calculateViewVector` of the player's rotation, in floats (`getLookAngle`)."
  def look(player), do: view(player)

  defp view(player) do
    radians = Float32.round(:math.pi() / 180.0)
    xr = Float32.round(player.pitch * radians)
    yr = Float32.round(-player.yaw * radians)
    {yc, ys} = {Valimc.Data.Mth.cos(yr), Valimc.Data.Mth.sin(yr)}
    {xc, xs} = {Valimc.Data.Mth.cos(xr), Valimc.Data.Mth.sin(xr)}
    {Float32.round(ys * xc), -xs, Float32.round(yc * xc)}
  end

  defp crit(body, true), do: %{body | data: %{body.data | crit: true}}
  defp crit(body, false), do: body

  # An arrow drawn by infinite materials carries `intangible_projectile`:
  # only creative players pick it up, and the pickup item loses the mark.
  defp creative_only(body, %ItemStack{components: components} = arrow) do
    if Map.has_key?(components, "minecraft:intangible_projectile") do
      item = %{
        arrow
        | components: Map.delete(components, "minecraft:intangible_projectile"),
          count: 1
      }

      %{body | data: %{body.data | pickup: :creative_only, item: item}}
    else
      body
    end
  end

  # `Player.getProjectile`: an arrow in the off hand or main hand, else the
  # first in the inventory (hotbar first); `{slot, stack}` or nil.
  defp ammo(inventory, _kind) do
    Enum.find_value(
      [45, 36 + inventory.selected | Enum.to_list(36..44) ++ Enum.to_list(9..35)],
      fn slot ->
        case Inventory.get(inventory, slot) do
          %ItemStack{} = stack -> if name(stack) in @arrows, do: {slot, stack}
          nil -> nil
        end
      end
    )
  end

  # `ProjectileWeaponItem.draw` from `weapon`: the arrows of one shot,
  # `{:ok, arrows, inventory}` or `:none`. The first is the ammunition's
  # (`useAmmo`: what its `ammo_use` effects take, Infinity none); Multishot's
  # others are intangible copies. Infinite materials take none and shoot a
  # plain arrow when none is held.
  defp draw_ammo(state, weapon) do
    inventory = state.inventory

    found =
      case ammo(inventory, :any) do
        nil -> if inventory.infinite_materials, do: {nil, ItemStack.new("arrow")}
        found -> found
      end

    case found do
      nil ->
        :none

      {slot, projectile} ->
        levels = Enchant.levels(weapon)

        count =
          max(
            0,
            trunc(
              Enchant.value(
                :projectile_count,
                levels,
                %{this: Valimc.Player.Enchantments.view(state)},
                1
              )
            )
          )

        {drawn, inventory} =
          Enum.reduce(0..(count - 1)//1, {[], inventory}, fn i, {drawn, inventory} ->
            infinite = i > 0 or inventory.infinite_materials

            used =
              if infinite,
                do: 0,
                else: trunc(Enchant.value(:ammo_use, levels, %{tool: projectile.item_id}, 1))

            cond do
              used > projectile.count ->
                {drawn, inventory}

              used == 0 ->
                copy =
                  put_in(
                    %{projectile | count: 1}.components["minecraft:intangible_projectile"],
                    :unit
                  )

                {[copy | drawn], inventory}

              true ->
                left =
                  if projectile.count > used, do: %{projectile | count: projectile.count - used}

                {[%{projectile | count: used} | drawn],
                 Inventory.put(inventory, slot, left) |> Inventory.advance()}
            end
          end)

        if drawn == [], do: :none, else: {:ok, Enum.reverse(drawn), inventory}
    end
  end

  defp wear(state, hand) do
    slot = slot(state, hand)
    stack = Inventory.get(state.inventory, slot)
    {after_use, broken} = Durability.hurt_and_break(stack, 1, state.inventory.infinite_materials)
    inventory = state.inventory |> Inventory.put(slot, after_use) |> Inventory.advance()
    state = %{state | inventory: inventory}

    if broken do
      play(
        state,
        "minecraft:entity.item.break",
        "player",
        0.8,
        Float32.round(0.8 + float() * 0.4)
      )

      state |> ItemUse.stop_item_use()
    else
      state
    end
  end

  ## Making projectiles

  defp owner(player),
    do: %{
      uuid: player.uuid,
      id: player.entity_id,
      player: true,
      creative: player.game_mode.current == :creative,
      luck: Valimc.Living.Attributes.luck(player.living.effects)
    }

  # `getEyeY() - 0.1F` above the feet.
  defp launch_point(player) do
    {:ok, dimensions} = PlayerPose.dimensions(Map.get(player, :pose, :standing))
    eye = Float32.round(dimensions["eye_height"])
    {player.x, player.y + eye - Float32.round(0.1), player.z}
  end

  defp movement(player),
    do: {player.motion.known_movement, player.motion.on_ground}

  defp launch(state, body, position) do
    record = Store.body_record(body, :crypto.strong_rand_bytes(16), position)

    case Items.spawn(state, [record]) do
      :ok -> {:ok, state}
      _ -> :error
    end
  end

  ## Arrival

  @doc """
  `ThrownEnderpearl.onHit` for its owner: from a live player in this
  dimension, one landing in twenty (at a difficulty above peaceful, monsters
  spawning) leaves an endermite where the player stood; the player
  teleports to `position` keeping its rotation, at rest with no fall, takes
  5 `ender_pearl` damage, and the teleport sounds there.
  """
  def pearl(%{life_stage: :alive} = state, {x, y, z}) do
    player = state.player

    state =
      if :rand.uniform() < 0.05 and Valimc.World.GameRules.get(:spawn_monsters) and
           elem(Valimc.World.Clock.difficulty(), 0).level > 0 do
        {:ok, mite} = Valimc.Entity.Body.new("minecraft:endermite")
        mite = %{mite | yaw: player.yaw, pitch: player.pitch, head_yaw: player.yaw}

        record =
          Store.body_record(mite, :crypto.strong_rand_bytes(16), {player.x, player.y, player.z})

        _ = Items.spawn(state, [record])
        state
      else
        state
      end

    state = Teleports.apply(state, %{x: x, y: y, z: z, yaw: player.yaw, pitch: player.pitch})
    state = put_in(state.player.motion, %{state.player.motion | fall_distance: 0.0})

    {_, state} =
      Valimc.Player.Hurt.hurt(state, %{source: DamageSource.new(:ender_pearl), amount: 5.0})

    world_sound(state, "minecraft:entity.player.teleport", "player", {x, y, z}, 1.0, 1.0)
    state
  end

  def pearl(state, _position), do: state

  @doc "An admitted contact hit's event precedes its living effects, including a lethal sting."
  def hit_actions(state, actions, template) do
    if :puffer_sting in actions, do: send_packets(state, [Packets.puffer_sting()])
    splash(state, Enum.reject(actions, &(&1 == :puffer_sting)), template)
  end

  @doc """
  The effects a splash potion or an effect cloud gives the player:
  `{:add, id, [rung]}`, `{:heal, amount}` and `{:hurt, type, amount}` (the
  hit `template` with its type and amount).
  """
  def splash(%{life_stage: :alive} = state, actions, template) do
    Enum.reduce(actions, state, fn
      {:add, id, rung}, acc ->
        case Vitals.apply_effect(acc, id, rung) do
          {:ok, _, next} -> next
          _ -> acc
        end

      {:heal, amount}, acc ->
        Vitals.apply_effect_action(acc, {:heal, amount})

      {:curse, id, rung, limit}, acc ->
        curse(acc, id, rung, limit)

      {:support, regen, fatigue}, acc ->
        support(acc, regen, fatigue)

      {:hurt, type, amount}, acc ->
        hit =
          %{template | source: DamageSource.new(type), amount: amount} |> Map.delete(:direction)

        elem(Valimc.Player.Hurt.hurt(acc, hit), 1)
    end)
  end

  def splash(state, _actions, _template), do: state

  # An axolotl's thanks (`Axolotl.applySupportingEffects`, VMC-043e):
  # Regeneration for 100 ticks more (up to 2400) unless it has more, and no
  # Mining Fatigue.
  defp support(state, regen, fatigue) do
    state =
      case state.player.living.effects[regen] do
        [{ticks, _, _, _, _} | _] when ticks == -1 or ticks > 2399 ->
          state

        current ->
          previous = if current, do: elem(hd(current), 0), else: 0

          case Vitals.apply_effect(state, regen, [
                 {min(2400, 100 + previous), 0, false, true, true}
               ]) do
            {:ok, _, next} -> next
            _ -> state
          end
      end

    case Vitals.apply_effect(state, fatigue, :remove) do
      {:ok, _, next} -> next
      _ -> state
    end
  end

  # An elder guardian's curse (`MobEffectUtil.addEffectToPlayersAround`):
  # the effect unless the player has it as strong and for longer than
  # `limit` ticks, and its ghost (game event 10).
  defp curse(state, id, {_, amplifier, _, _, _} = rung, limit) do
    case state.player.living.effects[id] do
      [{ticks, current, _, _, _} | _]
      when current >= amplifier and (ticks == -1 or ticks > limit - 1) ->
        state

      _ ->
        state =
          case Vitals.apply_effect(state, id, [rung]) do
            {:ok, _, next} -> next
            _ -> state
          end

        send_packets(state, [Packets.packet("game_event", <<10, 1.0::float-32>>)])
        state
    end
  end

  @doc "The shooter's chime for an arrow that hit another player (game event 6)."
  def arrow_hit(state) do
    send_packets(state, [Packets.packet("game_event", <<6, 0.0::float-32>>)])
    state
  end

  ## Pickup

  @doc """
  Pick up a stuck arrow of `views` the player touches (`Player.aiStep`'s
  box inflated by 1, 0.5, 1), once its shake is over and its pickup rule
  allows: `{:ok, state}` or the state unchanged.
  """
  def pickup(state, views) do
    with true <- state.life_stage == :alive and state.player.game_mode.current != :spectator,
         {:ok, actor} <- Items.actor(state.player),
         {_, view} <- Enum.find(views, &touching?(&1, actor.box)),
         {:ok, owner} <- Items.owner_of(state, view),
         {:ok, inventory} <- Region.take_arrow(owner, actor, view.uuid, state.inventory) do
      state = %{state | inventory: inventory}

      send_packets(state, [
        Valimc.Menus.Packets.inventory(inventory),
        Packets.cursor(inventory.carried)
      ])

      state
    else
      _ -> state
    end
  end

  defp touching?({_, %{kind: :object, takeable: true, at: {x, y, z}}}, box) do
    {x0, y0, z0, x1, y1, z1} = box
    {ax0, ay0, az0, ax1, ay1, az1} = {x0 - 1.0, y0 - 0.5, z0 - 1.0, x1 + 1.0, y1 + 0.5, z1 + 1.0}

    x - 0.25 < ax1 and x + 0.25 > ax0 and y < ay1 and y + 0.5 > ay0 and z - 0.25 < az1 and
      z + 0.25 > az0
  end

  defp touching?(_view, _box), do: false

  @doc """
  `AbstractArrow.tryPickup` of `body` by a player with `inventory`:
  `{:ok, inventory}` when taken, else `:refused`.
  """
  def try_pickup(%{data: %{pickup: :allowed, item: item}}, inventory) do
    case Inventory.pickup_stack(inventory, item) do
      {:ok, next, nil, _} -> {:ok, next}
      _ -> :refused
    end
  end

  def try_pickup(%{data: %{pickup: :creative_only, returning: true, item: item}}, inventory) do
    if inventory.infinite_materials,
      do: {:ok, inventory},
      else: try_pickup(%{data: %{pickup: :allowed, item: item}}, inventory)
  end

  def try_pickup(%{data: %{pickup: :creative_only}}, inventory),
    do: if(inventory.infinite_materials, do: {:ok, inventory}, else: :refused)

  def try_pickup(_body, _inventory), do: :refused

  ## Sounds

  defp play(state, name, source, volume, pitch) do
    %{x: x, y: y, z: z} = state.player
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    packet = CombatPackets.sound(name, source, {x, y, z}, volume, pitch, seed)
    Movement.broadcast_player_packet(state, packet)
    send_packets(state, [packet])
    state
  end

  defp world_sound(state, name, source, position, volume, pitch) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    packet = CombatPackets.sound(name, source, position, volume, pitch, seed)
    {x, _, z} = position
    key = Grid.section(state.player.dimension, Grid.chunk_key(x, z))
    Valimc.World.publish(key, {:sound, position, 16.0, packet})
  end

  defp float, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
