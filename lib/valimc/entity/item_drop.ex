defmodule Valimc.Entity.ItemDrop do
  @moduledoc """
  Pure native launches: a player's throw from an accepted pose and supplied
  random draws (`launch/4`), and a block's popped loot (`pop/2`). No item
  ownership.
  """
  alias Valimc.Data.Float32
  import Bitwise
  @sin_scale 10_430.378350470453
  @max_random 0.9999999403953552

  def launch(%{x: x, y: y, z: z, yaw: yaw, pitch: pitch}, eye, kind, [r0, r1, r2, r3])
      when is_number(x) and abs(x) <= 29_999_984 and is_number(y) and abs(y) <= 1_000_000 and
             is_number(z) and abs(z) <= 29_999_984 and is_number(yaw) and abs(yaw) <= 1_000_000 and
             is_number(pitch) and abs(pitch) <= 1_000_000 and is_number(eye) and eye >= 0 and
             eye <= 8 and
             kind in [:directed, :scattered] do
    draws = [r0, r1, r2, r3]
    height = y + Float32.round(eye) - Float32.round(0.3)

    if abs(height) <= 1_000_000 and
         Enum.all?(draws, &(is_number(&1) and &1 >= 0 and &1 <= @max_random)) do
      {:ok,
       %{
         position: {x * 1.0, height, z * 1.0},
         velocity: velocity(kind, yaw, pitch, Enum.map(draws, &Float32.round/1)),
         pickup_delay: 40
       }}
    else
      {:error, :invalid_item_launch}
    end
  end

  def launch(_, _, _, _), do: {:error, :invalid_item_launch}

  defp velocity(:scattered, _, _, [radius, angle | _]) do
    radius = Float32.round(radius * Float32.round(0.5))
    angle = Float32.round(angle * Float32.round(6.2831855))

    {Float32.round(-sine(angle) * radius), Float32.round(0.2),
     Float32.round(cosine(angle) * radius)}
  end

  defp velocity(:directed, yaw, pitch, [angle, radius, up, down]) do
    yaw = Float32.round(Float32.round(yaw) * Float32.round(0.017453292))
    pitch = Float32.round(Float32.round(pitch) * Float32.round(0.017453292))
    sin_yaw = sine(yaw)
    cos_yaw = cosine(yaw)
    sin_pitch = sine(pitch)
    cos_pitch = cosine(pitch)
    angle = Float32.round(angle * Float32.round(6.2831855))
    radius = Float32.round(Float32.round(0.02) * radius)
    x = Float32.round(Float32.round(-sin_yaw * cos_pitch) * Float32.round(0.3))
    z = Float32.round(Float32.round(cos_yaw * cos_pitch) * Float32.round(0.3))
    y = Float32.round(Float32.round(-sin_pitch * Float32.round(0.3)) + Float32.round(0.1))
    y = Float32.round(y + Float32.round(Float32.round(up - down) * Float32.round(0.1)))
    {x + :math.cos(angle) * radius, y, z + :math.sin(angle) * radius}
  end

  defp sine(angle), do: trig(trunc(angle * @sin_scale))
  defp cosine(angle), do: trig(trunc(angle * @sin_scale + 16_384.0))
  defp trig(index), do: Float32.round(:math.sin((index &&& 65_535) / @sin_scale))

  @doc """
  The record of `stack` popped from cell `{x, y, z}` like vanilla
  `Block.popResource`: up to 0.25 off the cell centre, lowered by half the
  item's 0.25 height, launched at (±0.1, 0.2, ±0.1) with a 10-tick pickup
  delay.
  """
  def pop({x, y, z}, stack) do
    [dx, dy, dz, vx, vz] = for _ <- 1..5, do: :rand.uniform_real()

    %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5 + (dx * 0.5 - 0.25),
      y: y + 0.5 + (dy * 0.5 - 0.25) - 0.125,
      z: z + 0.5 + (dz * 0.5 - 0.25),
      stack: stack,
      motion: %Valimc.Entity.ItemMotionState{
        velocity: {vx * 0.2 - 0.1, 0.2, vz * 0.2 - 0.1},
        pickup_delay: 10
      }
    }
  end

  @doc """
  The record of `stack` popped from cell `{x, y, z}`'s face `face` (0..5,
  `Direction` order) like vanilla `Block.popResourceFromFace`: just outside
  the face, anywhere within a quarter of the centre along it, moving out of
  the face at 0.1 (and up 0.1 more), along it up to 0.1.
  """
  def pop_from_face({x, y, z}, face, stack) do
    {sx, sy, sz} =
      elem({{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}, face)

    across = fn step, half ->
      if step == 0, do: :rand.uniform_real() * 0.5 - 0.25, else: step * (0.5 + half)
    end

    out = fn step, low, high ->
      if step == 0, do: low + :rand.uniform_real() * (high - low), else: step * 0.1
    end

    %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5 + across.(sx, 0.125),
      y: y + 0.5 + across.(sy, 0.125) - 0.125,
      z: z + 0.5 + across.(sz, 0.125),
      stack: stack,
      motion: %Valimc.Entity.ItemMotionState{
        velocity:
          {out.(sx, -0.1, 0.1), if(sy == 0, do: :rand.uniform_real() * 0.1, else: sy * 0.1 + 0.1),
           out.(sz, -0.1, 0.1)},
        pickup_delay: 10
      }
    }
  end
end
