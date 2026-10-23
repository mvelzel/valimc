defmodule Valimc.Entity.Projectile do
  @moduledoc """
  The projectile bodies (VMC-037o): arrows, thrown snowballs, eggs, ender
  pearls and splash potions, small, large and dragon fireballs, and eyes of
  ender. Each is a `Valimc.Entity.Body` of kind `:object` whose data holds
  what vanilla's `Projectile` and its subclass keep between ticks: the owner
  (`%{uuid, id, player}`, its network id for the spawn packet), the ticks
  lived, the water and left-owner flags the kernel reads, the fire it burns
  with, and the type's own fields (an arrow's ground state, pickup rule,
  damage and critical flag, a thrown item's stack, a fireball's
  acceleration and explosion power, an eye's target and life).

  `input/3` is the kernel's input of a body (`Physics.Kernel.projectiles/5`)
  and `advance/2` the body after the kernel's step; `shoot/4` and
  `from_rotation/6` are vanilla's `Projectile.shoot` and `shootFromRotation`
  (the throws, the bow and crossbow, a mob's aim).
  """
  alias Valimc.Data.{EntityTypes, Float32, Mth}
  alias Valimc.Entity.Body
  alias Valimc.Protocol.ItemStack

  @arrow "minecraft:arrow"
  @eye "minecraft:eye_of_ender"
  @thrown ~w(minecraft:snowball minecraft:egg minecraft:ender_pearl minecraft:splash_potion)
  @fireballs ~w(minecraft:small_fireball minecraft:fireball minecraft:dragon_fireball)
  @types [@arrow, @eye | @thrown ++ @fireballs]

  @items %{
    @arrow => "arrow",
    @eye => "ender_eye",
    "minecraft:snowball" => "snowball",
    "minecraft:egg" => "egg",
    "minecraft:ender_pearl" => "ender_pearl",
    "minecraft:splash_potion" => "splash_potion",
    "minecraft:small_fireball" => "fire_charge",
    "minecraft:fireball" => "fire_charge"
  }

  @radians_to_degrees 57.2957763671875

  @doc "The projectile types."
  def types, do: @types

  @doc "Whether `type` is a projectile's."
  def projectile?(type), do: type in @types

  @doc "Whether `type` is a thrown item's (`ThrowableItemProjectile`)."
  def thrown?(type), do: type in @thrown

  @doc "Whether `type` is a fireball's (`AbstractHurtingProjectile`)."
  def fireball?(type), do: type in @fireballs

  @doc "A type's data and its defaults (`Body.new/1`)."
  def data(type) do
    common = %{owner: nil, age: 0, in_water: false, left_owner: false, fire: 0, impulse: 0}
    Map.merge(common, own_data(type))
  end

  defp own_data(@arrow),
    do: %{
      in_ground: false,
      last_state: -1,
      life: 0,
      shake: 0,
      pickup: :disallowed,
      damage: 2.0,
      crit: false,
      item: item(@arrow),
      sound: "minecraft:entity.arrow.hit",
      weapon: nil
    }

  defp own_data(@eye), do: %{item: item(@eye), target: nil, life: 0, survive: true}
  defp own_data("minecraft:fireball"), do: %{acceleration: 0.1, power: 1}
  defp own_data(type) when type in @fireballs, do: %{acceleration: 0.1}
  defp own_data(type) when type in @thrown, do: %{item: item(type)}

  defp item(type), do: ItemStack.new(Map.fetch!(@items, type))

  @doc "The item a projectile shows (and an arrow drops), as `getItem` / `getPickupItem`."
  def stack(%Body{data: %{item: stack}}), do: stack
  def stack(%Body{type: type}), do: if(@items[type], do: item(type))

  @doc """
  A new projectile body of `type` from `owner` (`%{uuid, id, player}` or
  nil) carrying `stack` (the thrown or shot item, one of it).
  """
  def new(type, owner, stack \\ nil) do
    {:ok, body} = Body.new(type)
    data = %{body.data | owner: owner}

    data =
      if stack != nil and Map.has_key?(data, :item), do: %{data | item: one(stack)}, else: data

    # `AbstractArrow.setOwner`: a player's arrow may be picked up.
    data =
      if type == @arrow and match?(%{player: true}, owner),
        do: %{data | pickup: :allowed},
        else: data

    %{body | data: data}
  end

  defp one(%ItemStack{} = stack), do: %{stack | count: 1}

  ## Shooting

  @doc """
  `Projectile.shoot`: the body moving along `direction` at `power`, with
  `uncertainty`'s noise (`random.triangle(0, 0.0172275 * uncertainty)` per
  axis), turned to its motion.
  """
  def shoot(%Body{} = body, direction, power, uncertainty) do
    spread = 0.0172275 * uncertainty
    noise = for _ <- 1..3, do: spread * (:rand.uniform() - :rand.uniform())
    {x, y, z} = normalize(direction)
    [nx, ny, nz] = noise
    p = Float32.round(power)
    velocity = {(x + nx) * p, (y + ny) * p, (z + nz) * p}
    {yaw, pitch} = facing(velocity)
    data = if Map.has_key?(body.data, :life), do: %{body.data | life: 0}, else: body.data
    %{body | velocity: velocity, yaw: yaw, pitch: pitch, data: impulse(data)}
  end

  @doc """
  `Projectile.shootFromRotation`: shot along `{pitch, yaw}` (plus `offset`
  to the pitch) at `power`, then given the shooter's `movement` (`{velocity,
  on_ground}`: its vertical part only off the ground).
  """
  def from_rotation(%Body{} = body, {pitch, yaw}, offset, power, uncertainty, movement) do
    radians = Float32.round(:math.pi() / 180.0)
    yr = Float32.round(yaw * radians)
    xr = Float32.round(pitch * radians)
    xd = Float32.round(-Mth.sin(yr) * Mth.cos(xr))
    yd = Float32.round(-Mth.sin(Float32.round(Float32.round(pitch + offset) * radians)))
    zd = Float32.round(Mth.cos(yr) * Mth.cos(xr))
    body = shoot(body, {xd, yd, zd}, power, uncertainty)
    {{mx, my, mz}, on_ground} = movement
    {vx, vy, vz} = body.velocity
    %{body | velocity: {vx + mx, vy + if(on_ground, do: 0.0, else: my), vz + mz}}
  end

  @doc "A body's rotation toward its motion, as `shoot` sets it."
  def facing({x, y, z}) do
    horizontal = :math.sqrt(x * x + z * z)

    {Float32.round(atan2(x, z) * @radians_to_degrees),
     Float32.round(atan2(y, horizontal) * @radians_to_degrees)}
  end

  defp atan2(y, x) when y == 0 and x == 0, do: 0.0
  defp atan2(y, x), do: :math.atan2(y, x)

  @doc "`Vec3.normalize`."
  def normalize({x, y, z}) do
    d = :math.sqrt(x * x + y * y + z * z)
    if d < Float32.round(1.0e-5), do: {0.0, 0.0, 0.0}, else: {x / d, y / d, z / d}
  end

  @doc "The body marked for an immediate update (vanilla's `needsSync`)."
  def impulse(%Body{data: data} = body), do: %{body | data: impulse(data)}
  def impulse(%{impulse: n} = data), do: %{data | impulse: n + 1}

  ## The kernel

  @doc """
  The kernel input of projectile `body` at `position` with three floats of
  its random (`Physics.Kernel.projectiles/5`).
  """
  def input(%Body{type: type, data: d} = body, position, random) do
    state =
      {position, body.velocity, {body.yaw * 1.0, body.pitch * 1.0}, d.age,
       {d.in_water, Map.get(d, :in_ground, false), d.left_owner}, Map.get(d, :last_state, -1)}

    %{width: width, height: height} = EntityTypes.fetch(type)
    owner = if d.owner, do: d.owner.id
    {state, kind(body), {width * 1.0, height * 1.0}, random, owner}
  end

  defp kind(%Body{type: @arrow} = body), do: {:arrow, gravity(body, 0.05)}
  defp kind(%Body{type: "minecraft:splash_potion"} = body), do: {:throwable, gravity(body, 0.05)}
  defp kind(%Body{type: type} = body) when type in @thrown, do: {:throwable, gravity(body, 0.03)}
  defp kind(%Body{type: @eye, data: data}), do: {:eye, data.target}
  defp kind(%Body{data: data}), do: {:hurting, data.acceleration}

  defp gravity(%Body{no_gravity: true}, _), do: 0.0
  defp gravity(_body, gravity), do: gravity

  @doc """
  The body after the kernel's step `state` (`{position, velocity, {yaw,
  pitch}, age, {in_water, in_ground, left_owner}, last_state}`), with the
  lava it touched (`lava` depth) setting it on fire, water putting it out,
  and a fireball that burns (small and large) burning again.
  """
  def advance(
        %Body{type: type, data: d} = body,
        {_, velocity, {yaw, pitch}, age, flags, last},
        lava \\ 0.0
      ) do
    {in_water, in_ground, left_owner} = flags
    fire = max(d.fire - 1, 0)

    fire =
      if lava > 0.0 and not EntityTypes.fetch(type).fire_immune, do: max(fire, 300), else: fire

    fire = if in_water, do: 0, else: fire
    fire = if type in ["minecraft:small_fireball", "minecraft:fireball"], do: 20, else: fire
    data = %{d | age: age, in_water: in_water, left_owner: left_owner, fire: fire}

    data =
      if type == @arrow,
        do: %{data | in_ground: in_ground, last_state: last, shake: max(data.shake - 1, 0)},
        else: data

    %{body | velocity: velocity, yaw: yaw, pitch: pitch, data: data}
  end

  ## Entity data

  @doc "The type's own entity data values, with vanilla's defaults (`Body.values/1`)."
  def values(%Body{type: @arrow, data: d}) do
    flags = if d.crit, do: 1, else: 0

    [
      {:arrow_flags, flags, 0},
      {:arrow_pierce_level, 0, 0},
      {:arrow_in_ground, d.in_ground, false},
      {:arrow_color, -1, -1}
    ]
  end

  # Thrown items and eyes are given their stack when made, which vanilla
  # always sends (an item stack never equals the defined default).
  def values(%Body{type: type, data: d}) when type in @thrown, do: [{:thrown_item, d.item, nil}]
  def values(%Body{type: @eye, data: d}), do: [{:eye_item, d.item, nil}]
  def values(_body), do: []

  @doc "The on-fire flag (shared flag bit 0) of a burning projectile."
  def burning?(%Body{data: %{fire: fire}}), do: fire > 0

  @doc "The spawn packet's data: the owner's network id, or 0 (`Projectile.getAddEntityPacket`)."
  def spawn_data(%Body{type: @eye}), do: 0
  def spawn_data(%Body{data: %{owner: %{id: id}}}), do: id
  def spawn_data(_body), do: 0
end
