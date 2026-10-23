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
  alias Valimc.Living.{DamageSource, Durability}
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
  # `CrossbowItem.getChargeDuration` without Quick Charge: 1.25 seconds.
  @charge 25
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
      _ -> nil
    end
  end

  @doc "A use of the projectile item `stack` in `hand`."
  def use(state, hand, stack) do
    case {Map.fetch(@thrown, name(stack)), weapon(stack)} do
      {{:ok, throw}, _} -> throw(state, hand, stack, throw)
      {:error, :bow} -> draw(state, hand, stack, :bow)
      {:error, :crossbow} -> crossbow(state, hand, stack)
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
  The release of a drawn bow (`BowItem.releaseUsing`): an arrow at the
  power of the ticks drawn. Any use ends.
  """
  def release(%{active_use: %Use{kind: :bow} = use} = state) do
    bow = Inventory.held(state.inventory, use.hand)
    power = power(Use.elapsed(use))

    state =
      with true <- power >= 0.1,
           %ItemStack{} <- bow,
           {:ok, arrow, inventory} <- take_ammo(state.inventory, :bow) do
        player = state.player
        state = %{state | inventory: inventory}

        body =
          "minecraft:arrow"
          |> Projectile.new(owner(player), arrow)
          |> creative_only(arrow)
          |> crit(power == 1.0)
          |> Projectile.from_rotation(
            {player.pitch, player.yaw},
            0.0,
            Float32.round(power * 3.0),
            1.0,
            movement(player)
          )

        state =
          case launch(state, body, launch_point(player)) do
            {:ok, state} -> wear(state, use.hand)
            :error -> state
          end

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

  def release(state), do: ItemUse.stop_item_use(state)

  @doc "`BowItem.getPowerForTime`."
  def power(ticks) do
    p = Float32.round(ticks / 20.0)
    min(Float32.round(Float32.round(Float32.round(p * p) + Float32.round(p * 2.0)) / 3.0), 1.0)
  end

  @doc """
  One tick of a charging crossbow (`CrossbowItem.onUseTick`): its loading
  sounds at a fifth and half of the charge, and the arrow loaded once full.
  """
  def charge(%{active_use: %Use{kind: :crossbow} = use} = state) do
    progress = Float32.round(Use.elapsed(use) / @charge)
    loads = Map.get(use, :sounds, 0)

    cond do
      progress >= 1.0 and loads < 3 ->
        crossbow = Inventory.held(state.inventory, use.hand)

        with %ItemStack{} <- crossbow,
             nil <- ItemStack.component(crossbow, "minecraft:charged_projectiles") |> loaded(),
             {:ok, arrow, inventory} <- take_ammo(state.inventory, :crossbow) do
          charged =
            put_in(crossbow.components["minecraft:charged_projectiles"], [%{arrow | count: 1}])

          inventory =
            inventory |> Inventory.put(slot(state, use.hand), charged) |> Inventory.advance()

          state = CreativeInventory.resync_inventory(%{state | inventory: inventory})
          pitch = Float32.round(Float32.round(1.0 / Float32.round(float() * 0.5 + 1.0)) + 0.2)
          play(state, "minecraft:item.crossbow.loading_end", "player", 1.0, pitch)
          %{state | active_use: %{use | sounds: 3}}
        else
          _ -> %{state | active_use: %{use | sounds: 3}}
        end

      progress >= 0.5 and loads < 2 ->
        play(state, "minecraft:item.crossbow.loading_middle", "player", 0.5, 1.0)
        %{state | active_use: %{use | sounds: 2}}

      progress >= 0.2 and loads < 1 ->
        play(state, "minecraft:item.crossbow.loading_start", "player", 0.5, 1.0)
        %{state | active_use: %{use | sounds: 1}}

      true ->
        state
    end
  end

  def charge(state), do: state

  defp loaded([_ | _]), do: :loaded
  defp loaded(_), do: nil

  # `CrossbowItem.performShooting` of its loaded arrow: along the view at
  # 3.15, critical, with the crossbow's hit sound.
  defp shoot_crossbow(state, hand, crossbow, [arrow | _]) do
    player = state.player
    emptied = put_in(crossbow.components["minecraft:charged_projectiles"], [])

    inventory =
      state.inventory |> Inventory.put(slot(state, hand), emptied) |> Inventory.advance()

    state = %{state | inventory: inventory}

    body =
      "minecraft:arrow"
      |> Projectile.new(owner(player), arrow)
      |> creative_only(arrow)
      |> crit(true)
      |> then(&%{&1 | data: %{&1.data | sound: "minecraft:item.crossbow.hit"}})
      |> Projectile.shoot(view(player), 3.15, 1.0)

    state =
      case launch(state, body, launch_point(player)) do
        {:ok, state} -> wear(state, hand)
        :error -> state
      end

    play(state, "minecraft:item.crossbow.shoot", "player", 1.0, 1.0)
    CreativeInventory.resync_inventory(state)
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

  # `ProjectileWeaponItem.useAmmo`: one arrow from the stack, or with
  # infinite materials a copy marked intangible (a plain arrow if none is held).
  defp take_ammo(inventory, kind) do
    case {ammo(inventory, kind), inventory.infinite_materials} do
      {nil, true} ->
        {:ok, put_in(ItemStack.new("arrow").components["minecraft:intangible_projectile"], :unit),
         inventory}

      {{_, stack}, true} ->
        {:ok, put_in(%{stack | count: 1}.components["minecraft:intangible_projectile"], :unit),
         inventory}

      {{slot, stack}, false} ->
        left = if stack.count > 1, do: %{stack | count: stack.count - 1}, else: nil
        {:ok, %{stack | count: 1}, Inventory.put(inventory, slot, left) |> Inventory.advance()}

      {nil, false} ->
        :none
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

  defp owner(player), do: %{uuid: player.uuid, id: player.entity_id, player: true}

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

      {:hurt, type, amount}, acc ->
        hit =
          %{template | source: DamageSource.new(type), amount: amount} |> Map.delete(:direction)

        elem(Valimc.Player.Hurt.hurt(acc, hit), 1)
    end)
  end

  def splash(state, _actions, _template), do: state

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
