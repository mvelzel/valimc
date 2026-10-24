defmodule Valimc.AI.Dragon.Flight do
  @moduledoc """
  One dragon's free flight and eight part positions (VMC-045a2). The actor
  records its height/yaw before choosing a phase target, then steers once.
  Parts share its 64-sample history; they are boxes, never separate owners.
  """
  alias Valimc.AI.{Mth, Dragon.Facts}
  alias Valimc.Data.Float32
  alias Valimc.Data.Mth, as: Trig

  @rad Float32.round(:math.pi() / 180.0)
  @deg Float32.round(180.0 / Float32.round(:math.pi()))

  defstruct position: {0.0, 0.0, 0.0},
            velocity: {0.0, 0.0, 0.0},
            yaw: 0.0,
            turn: 0.0,
            history: nil,
            parts:
              {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0},
               {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}

  @doc "Wrap yaw and record the pre-phase sample. NoAI records nothing."
  def begin_tick(state, no_ai \\ false) do
    state = %{state | yaw: Mth.wrap(state.yaw)}
    if no_ai, do: state, else: record(state)
  end

  defp record(%{position: {_, y, _}, yaw: yaw} = state) do
    sample = {y, yaw}

    history =
      case state.history do
        nil ->
          {0, List.duplicate(sample, 64) |> List.to_tuple()}

        {head, samples} ->
          head = rem(head + 1, 64)
          {head, put_elem(samples, head, sample)}
      end

    %{state | history: history}
  end

  @doc "A complete movement tick where no phase callback changes the state."
  def step(state, target, phase, wall \\ false, no_ai \\ false) do
    state = begin_tick(state, no_ai)
    if no_ai, do: state, else: advance(state, target, phase, wall)
  end

  @doc "Move toward the chosen target and place parts using the recorded history."
  def advance(state, target, phase, wall \\ false) do
    profile = Facts.phase(phase)
    state = if target, do: steer(state, target, profile, wall), else: state
    %{state | parts: parts(state, profile.sitting)}
  end

  defp steer(state, target, profile, wall) do
    {dx, dy, dz} = subtract(target, state.position)
    distance = dx * dx + dy * dy + dz * dz
    horizontal = :math.sqrt(dx * dx + dz * dz)

    dy =
      if horizontal > 0.0, do: Mth.clamp(dy / horizontal, -profile.speed, profile.speed), else: dy

    {vx, vy, vz} = state.velocity
    vy = vy + dy * 0.01
    radians = f(state.yaw * @rad)
    direction = normalize({Trig.sin(radians), vy, -Trig.cos(radians)})

    alignment =
      max(f(f(f(dot(direction, normalize({dx, dy_target(target, state), dz}))) + 0.5) / 1.5), 0.0)

    {yaw, turn} =
      if abs(dx) > f(1.0e-5) or abs(dz) > f(1.0e-5) do
        delta =
          Mth.clamp(
            Mth.wrap(f(f(180.0 - f(f(Mth.atan2(dx, dz)) * @deg)) - state.yaw)),
            -50.0,
            50.0
          )

        rotation_speed = f(f(:math.sqrt(vx * vx + vz * vz)) + 1.0)
        limited = min(rotation_speed, 40.0)

        gain =
          if profile.landing,
            do: f(limited / rotation_speed),
            else: f(f(f(0.7) / limited) / rotation_speed)

        turn = f(f(state.turn * f(0.8)) + f(delta * gain))
        {f(state.yaw + f(turn * f(0.1))), turn}
      else
        {state.yaw, state.turn}
      end

    span = f(2.0 / (distance + 1.0))
    speed = f(f(0.06) * f(f(alignment * span) + f(1.0 - span)))
    radians = f(yaw * @rad)
    velocity = {vx + speed * Trig.sin(radians), vy, vz - speed * Trig.cos(radians)}
    position = add(state.position, scale(velocity, if(wall, do: f(0.8), else: 1.0)))
    slide = 0.8 + 0.15 * (dot(normalize(velocity), direction) + 1.0) / 2.0
    {vx, vy, vz} = velocity

    %{
      state
      | position: position,
        velocity: {vx * slide, vy * f(0.91), vz * slide},
        yaw: yaw,
        turn: turn
    }
  end

  defp dy_target({_, ty, _}, %{position: {_, y, _}}), do: ty - y

  defp parts(state, sitting) do
    {y5, yaw5} = sample(state, 5)
    {y10, _} = sample(state, 10)
    {y0, _} = sample(state, 0)
    tilt = f(f(f(y5 - y10) * 10.0) * @rad)
    st = Trig.sin(tilt)
    ct = Trig.cos(tilt)
    rad = f(state.yaw * @rad)
    s = Trig.sin(rad)
    c = Trig.cos(rad)
    bend = f(rad - f(state.turn * f(0.01)))
    sb = Trig.sin(bend)
    cb = Trig.cos(bend)
    offset = if sitting, do: -1.0, else: f(y5 - y0)
    head = {f(f(sb * 6.5) * ct), f(offset + f(st * 6.5)), f(f(-cb * 6.5) * ct)}
    neck = {f(f(sb * 5.5) * ct), f(offset + f(st * 5.5)), f(f(-cb * 5.5) * ct)}

    tails =
      for i <- 0..2 do
        {y, yaw} = sample(state, 12 + i * 2)
        turn = f(rad + f(Mth.wrap(f(yaw - yaw5)) * @rad))
        length = (i + 1) * 2.0

        {f(-f(f(s * 1.5) + f(Trig.sin(turn) * length)) * ct),
         y - y5 - f(f(length + 1.5) * st) + 1.5,
         f(f(f(c * 1.5) + f(Trig.cos(turn) * length)) * ct)}
      end

    ([head, neck, {f(s * 0.5), 0.0, f(-c * 0.5)}] ++
       tails ++
       [{f(c * 4.5), 2.0, f(s * 4.5)}, {f(c * -4.5), 2.0, f(s * -4.5)}])
    |> Enum.map(&add(state.position, &1))
    |> List.to_tuple()
  end

  defp sample(%{history: {head, samples}}, delay),
    do: elem(samples, Integer.mod(head - delay, 64))

  @doc "The eight part boxes in the client's implicit network-id order."
  def boxes(state) do
    for {{_name, width, height}, {x, y, z}} <- Enum.zip(Facts.parts(), Tuple.to_list(state.parts)) do
      half = f(width / 2.0)
      {x - half, y, z - half, x + half, y + height, z + half}
    end
  end

  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
  defp scale({x, y, z}, n), do: {x * n, y * n, z * n}
  defp dot({x, y, z}, {a, b, c}), do: x * a + y * b + z * c

  defp normalize(v) do
    length = :math.sqrt(dot(v, v))
    if length < 1.0e-5, do: {0.0, 0.0, 0.0}, else: divide(v, length)
  end

  defp divide({x, y, z}, n), do: {x / n, y / n, z / n}
  defp f(v), do: Float32.round(v)
end
