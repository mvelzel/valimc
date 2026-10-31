defmodule Valimc.Living.Melee do
  @moduledoc """
  Vanilla's melee rules (VMC-037n), pure and in vanilla's float arithmetic:

  - a player's attack strength (`Player.getAttackStrengthScale`) and what an
    attack deals (`Player.attack`: the strength scale on the attack damage and
    the weapon's enchantment bonus, criticals, sprint knockback, the sweep);
  - knockback (`LivingEntity.knockback`) and its direction from an attacker's
    yaw (`causeExtraKnockback`);
  - shield blocking (`BlocksAttacks`): the blocked share of a hit by the angle
    to its source, and the wear it puts on the shield.
  """
  alias Valimc.Data.{Float32, Mth}

  # `(float) (Math.PI / 180.0)` and `1.0E-5F`.
  @deg 0.01745329238474369
  @epsilon 9.999999747378752e-6

  @doc "The knockback of a hit and of a sweep: `0.4F`, widened."
  def default_knockback, do: 0.4000000059604645

  @doc "`getCurrentItemAttackStrengthDelay`: ticks to full strength, or :infinity at zero speed."
  def strength_delay(attack_speed) when attack_speed == 0, do: :infinity
  def strength_delay(attack_speed), do: Float32.round(1.0 / attack_speed * 20.0)

  @doc "`getAttackStrengthScale(a)` after `ticker` ticks at `attack_speed`."
  def strength(ticker, attack_speed, a \\ 0.5)
  def strength(_ticker, attack_speed, _a) when attack_speed == 0, do: 0.0

  def strength(ticker, attack_speed, a),
    do:
      Float32.round(
        min(
          1.0,
          max(0.0, Float32.round(Float32.round(ticker + a) / strength_delay(attack_speed)))
        )
      )

  @doc """
  `cannotAttackWithItem(stack, tolerance)`: whether the item's minimum charge
  is not reached even `tolerance` ticks later.
  """
  def too_weak?(minimum, _ticker, attack_speed, _tolerance) when attack_speed == 0,
    do: minimum > 0.0

  def too_weak?(minimum, ticker, attack_speed, tolerance),
    do:
      minimum > 0.0 and
        Float32.round(Float32.round(ticker + tolerance) / strength_delay(attack_speed)) < minimum

  @doc """
  What a player's attack deals (`Player.attack`): `attack` holds `:damage`
  (the attack damage attribute), `:enchanted` (that damage after the weapon's
  enchantments against this target), `:strength` (`strength/3`),
  `:sprinting`, `:critical` (the conditions of `canCriticalAttack`) and
  `:sweep` (`isSweepAttack`'s conditions besides strength, criticals and
  sprinting). `{:ok, hit}` with the damage, the base the sweep scales, the
  magic boost and the flags, or `:none` for an attack that deals nothing.
  """
  def attack(%{damage: damage, enchanted: enchanted, strength: strength} = attack) do
    base = Float32.round(damage)
    magic = Float32.round(strength * Float32.round(Float32.round(enchanted) - base))
    # `0.2F + scale * scale * 0.8F`, in float.
    scale =
      Float32.round(
        Float32.round(0.2) +
          Float32.round(Float32.round(strength * strength) * Float32.round(0.8))
      )

    base = Float32.round(base * scale)

    if base > 0.0 or magic > 0.0 do
      full = strength > 0.9
      knockback = attack.sprinting and full
      # `getAttackDamageBonus` of the weapon (a mace's smash, VMC-037q).
      base = Float32.round(base + Map.get(attack, :bonus, 0.0))
      critical = full and attack.critical
      base = if critical, do: Float32.round(base * 1.5), else: base

      {:ok,
       %{
         damage: Float32.round(base + magic),
         base: base,
         magic: magic,
         full: full,
         critical: critical,
         sprint_knockback: knockback,
         sweep: full and not critical and not knockback and attack.sweep
       }}
    else
      :none
    end
  end

  @doc "The damage a sweep deals around the target before enchantments: `1 + ratio * base`."
  def sweep_damage(ratio, base),
    do: Float32.round(1.0 + Float32.round(Float32.round(ratio) * base))

  @doc """
  `isSweepAttack`'s movement condition: the attacker's known horizontal
  movement is below 2.5 times its speed.
  """
  def slow_enough?({dx, _dy, dz}, speed), do: dx * dx + dz * dz < speed * 2.5 * (speed * 2.5)

  @doc """
  `LivingEntity.knockback(power, xd, zd)` on a body moving at `velocity`:
  its new velocity, or the same when knockback resistance cancels it. `draws`
  are two pairs of random doubles for a direction too small to normalize.
  """
  def knockback({vx, vy, vz}, on_ground, power, {xd, zd}, resistance, draws \\ []) do
    power = power * (1.0 - resistance)

    if power <= 0.0 do
      {vx, vy, vz}
    else
      {xd, zd} = direction(xd, zd, draws)
      length = :math.sqrt(xd * xd + zd * zd)
      {nx, nz} = if length < @epsilon, do: {0.0, 0.0}, else: {xd / length, zd / length}
      {dx, dz} = {nx * power, nz * power}

      {vx / 2.0 - dx, if(on_ground, do: min(0.4, vy / 2.0 + power), else: vy), vz / 2.0 - dz}
    end
  end

  # `while (xd * xd + zd * zd < 1.0E-5F)`: random tiny directions.
  defp direction(xd, zd, draws) do
    if xd * xd + zd * zd < @epsilon do
      case draws do
        [{a, b}, {c, d} | rest] ->
          direction((a - b) * 0.01, (c - d) * 0.01, rest)

        _ ->
          direction(
            (:rand.uniform() - :rand.uniform()) * 0.01,
            (:rand.uniform() - :rand.uniform()) * 0.01,
            []
          )
      end
    else
      {xd, zd}
    end
  end

  @doc """
  The knockback direction of an attacker facing `yaw` degrees
  (`causeExtraKnockback`): `{sin(yaw), -cos(yaw)}`.
  """
  def facing(yaw) do
    radians = Float32.round(Float32.round(yaw) * @deg)
    {Mth.sin(radians), -Mth.cos(radians)}
  end

  @doc """
  The angle between where a blocker faces (`head_yaw` degrees) and the
  horizontal direction from `position` to `source` (`applyItemBlocking`); pi
  without a source position.
  """
  def blocking_angle(_position, _head_yaw, nil), do: :math.pi()

  def blocking_angle({x, _, z}, head_yaw, {sx, _, sz}) do
    # `calculateViewVector(0, yHeadRot)`.
    g = Float32.round(-Float32.round(head_yaw) * @deg)
    {vx, vz} = {Mth.sin(g), Mth.cos(g)}
    {dx, dz} = {sx - x, sz - z}
    length = :math.sqrt(dx * dx + dz * dz)
    {dx, dz} = if length < @epsilon, do: {0.0, 0.0}, else: {dx / length, dz / length}
    :math.acos(max(-1.0, min(1.0, dx * vx + dz * vz)))
  end

  @doc """
  `BlocksAttacks.resolveBlockedDamage`: the share of `damage` a shield blocks
  at `angle` from a source of type `type` (`in_set?` answers a damage type
  set).
  """
  def blocked(blocks, type, damage, angle, in_set?) do
    total =
      Enum.reduce(blocks.reductions, 0.0, fn r, acc ->
        cond do
          angle > Float32.round(@deg * r.angle) ->
            acc

          r.types != nil and not in_set?.(r.types, type) ->
            acc

          true ->
            Float32.round(acc + min(damage, max(0.0, Float32.round(r.base + r.factor * damage))))
        end
      end)

    min(damage, max(0.0, total))
  end

  @doc "`ItemDamageFunction.apply`: the wear a blocked hit puts on the shield."
  def shield_wear({threshold, base, factor}, blocked),
    do:
      if(blocked < threshold,
        do: 0,
        else: floor(Float32.round(base + Float32.round(factor * blocked)))
      )

  @doc "`blockDelayTicks`: ticks a shield is raised before it blocks."
  def block_delay(blocks), do: floor(Float32.round(blocks.delay * 20.0) + 0.5)
end
