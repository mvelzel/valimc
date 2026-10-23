defmodule Valimc.Player.Explosions do
  @moduledoc """
  An explosion near a hosted player (VMC-050a), as its group hands it to the
  session: the player's share of `ServerExplosion.hurtEntities` and of
  `ServerLevel.explode`'s packets. A player within 64 blocks is sent the
  explode packet; one within reach (not a spectator) is hurt by the
  `:explosion` damage type, scaled by the difficulty, and pushed. The push
  is the packet's knockback unless the player flies in creative, and the
  server's own velocity takes it as vanilla's `push` does. Explosion
  knockback resistance (Blast Protection) is not modelled yet.

  A landing anvil (VMC-050a2) hurts a living player in its box who is in
  neither creative nor spectator mode (`FallingBlockEntity.causeFallDamage`).
  """
  alias Valimc.Data.PlayerPose
  alias Valimc.Living.{DamageSource, Explosions, Health}
  alias Valimc.Physics.Kernel
  alias Valimc.Player.{Kinetics, Vitals}
  alias Valimc.Protocol.ExplodePacket
  alias Valimc.World.Explosion
  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @doc "The session after `explosion`, whose rays reached `count` cells."
  def hit(%{phase: :play, player: player} = state, %Explosion{center: center} = explosion, count) do
    feet = {player.x, player.y, player.z}

    if squared(feet, center) >= 4096.0 do
      state
    else
      {state, knockback} = affect(state, explosion)

      packet =
        ExplodePacket.packet(
          center,
          explosion.radius,
          count,
          knockback,
          Explosion.small?(explosion)
        )

      send_packets(state, [packet])
      state
    end
  end

  def hit(state, _explosion, _count), do: state

  defp affect(%{player: player} = state, %Explosion{center: center, radius: radius}) do
    feet = {player.x, player.y, player.z}
    pose = Map.get(player, :pose, :standing)
    {:ok, geometry} = PlayerPose.geometry(pose, feet)
    distance = Explosions.distance(radius, center, feet)

    if player.game_mode.current == :spectator or distance == nil or
         not intersects?(geometry.box, Explosions.reach(radius, center)) do
      {state, nil}
    else
      {:ok, [seen]} = Kernel.exposure(Valimc.World.View.new(), center, [geometry.box])
      damage = Explosions.damage(radius, center, feet, seen)
      state = hurt(state, damage, :explosion)
      impulse = Explosions.knockback(center, geometry.eye, distance, seen)
      state = push(state, impulse)

      flying = player.game_mode.current == :creative and player.abilities.flying
      {state, if(flying, do: nil, else: impulse)}
    end
  end

  @doc "The session after an anvil landing in `box` with `amount` of damage."
  def falling_block(%{phase: :play, player: player} = state, box, amount) do
    {:ok, geometry} =
      PlayerPose.geometry(Map.get(player, :pose, :standing), {player.x, player.y, player.z})

    if player.game_mode.current in [:survival, :adventure] and intersects?(geometry.box, box),
      do: hurt(state, amount, :falling_anvil),
      else: state
  end

  def falling_block(state, _box, _amount), do: state

  # `Player.hurtServer`: a source that scales takes the difficulty's share;
  # no damage is no hit.
  defp hurt(state, damage, source) do
    {difficulty, _} = Valimc.World.Clock.difficulty()

    amount =
      if DamageSource.scales_with_difficulty?(source),
        do: Explosions.scale(damage, difficulty.level),
        else: damage

    with true <- amount > 0.0,
         {:ok, selected} <- Health.hurt_window(state.player.living.health, amount) do
      {_, state} = Vitals.apply_damage(state, selected, source)
      state
    else
      _ -> state
    end
  end

  defp push(%{player: player} = state, {dx, dy, dz}) do
    {x, y, z} = Kinetics.velocity(player)
    velocity = {x + dx, y + dy, z + dz}

    if Map.has_key?(player, :motion) and Kinetics.admissible?(player, velocity),
      do: %{state | player: %{player | motion: %{player.motion | velocity: velocity}}},
      else: state
  end

  defp intersects?({a0, b0, c0, a1, b1, c1}, {x0, y0, z0, x1, y1, z1}),
    do: a0 < x1 and a1 > x0 and b0 < y1 and b1 > y0 and c0 < z1 and c1 > z0

  defp squared({x, y, z}, {cx, cy, cz}),
    do: (x - cx) * (x - cx) + (y - cy) * (y - cy) + (z - cz) * (z - cz)
end
