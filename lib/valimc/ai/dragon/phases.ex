defmodule Valimc.AI.Dragon.Phases do
  @moduledoc """
  Dragon phase decisions and their flight (VMC-045a3). The owner supplies
  the fixed arena graph, podium, combat-eligible players and block/visibility
  reads. Effects ask it to scan crystals, fire, breathe or finish dying.
  """
  import Bitwise
  alias Valimc.AI.{Mth, Random}
  alias Valimc.AI.Dragon.{Facts, Flight, Paths}
  alias Valimc.Data.Float32
  alias Valimc.Data.Mth, as: Trig
  @rad Float32.round(:math.pi() / 180.0)
  @pi Float32.round(:math.pi())

  defstruct phase: 10,
            flight: %Flight{},
            random: 0,
            target: nil,
            leaving: nil,
            path: nil,
            clockwise: %{0 => false, 1 => false},
            ticks: 0,
            flames: 0,
            attack: nil,
            charge: 0,
            first: true,
            flame_live: false,
            head_yaw: 0.0,
            pitch: 0.0,
            effects: []

  @doc "Enter a phase; its path/timers reset, its direction and flame count persist."
  def set(%{phase: phase} = state, phase), do: state

  def set(state, phase) when phase in 0..10 do
    effects = if state.flame_live, do: state.effects ++ [:end_flame], else: state.effects

    %{
      state
      | phase: phase,
        leaving: {state.phase, state.target},
        target: nil,
        path: nil,
        ticks: 0,
        attack: nil,
        charge: 0,
        first: true,
        flame_live: false,
        effects: effects,
        flames: state.flames + if(phase == 5, do: 1, else: 0)
    }
  end

  @doc "One alive tick, including the pre-phase crystal scan draw and a phase transition."
  def tick(state, env, no_ai \\ false) do
    {scan, random} = Random.int(state.random, 10)

    state = %{
      state
      | random: random,
        effects: if(scan == 0, do: [:scan_crystals], else: []),
        flight: Flight.begin_tick(state.flight, no_ai)
    }

    if no_ai do
      state
    else
      previous = state.phase
      state = decide(state, env)
      called = state.phase

      {state, called} =
        if called != previous, do: {decide(state, env), called}, else: {state, previous}

      # A second phase may transition again. Native flight still uses the
      # last phase that actually ran, including the target it left behind.
      target = if state.phase == called, do: state.target, else: elem(state.leaving, 1)
      %{state | flight: Flight.advance(state.flight, target, called, Map.get(env, :wall, false))}
    end
  end

  @doc "Strafe a combat-eligible player after a crystal hit or a holding decision."
  def strafe(state, player, env) do
    state = %{set(state, 1) | attack: player}
    {x, y, z} = player.position
    {dx, _, dz} = sub({floor(x), y, floor(z)}, state.flight.position)

    final =
      {floor(x), floor(y + min(f(0.4) + :math.sqrt(dx * dx + dz * dz) / 80.0 - 1.0, 10.0)),
       floor(z)}

    state
    |> route(
      env,
      closest(state, env),
      Paths.closest(env.graph, player.position, env.crystals),
      final
    )
    |> navigate()
  end

  defp decide(%{phase: 0} = state, env) do
    if retarget?(state, env) do
      if state.path == [] do
        {land, state} = draw(state, (env.crystals || 0) + 3)
        if land == 0, do: set(state, 2), else: choose_strafe(state, env)
      else
        circle(state, env)
      end
    else
      state
    end
  end

  defp decide(%{phase: 1, attack: nil} = state, _env), do: set(state, 0)

  defp decide(%{phase: 1} = state, env) do
    player = Enum.find(env.players, &(&1.id == state.attack.id)) || state.attack
    state = %{state | attack: player}
    {x, y, z} = player.position
    {dx, _, dz} = sub(player.position, state.flight.position)

    state =
      if state.path == [],
        do: %{
          state
          | target: {x, y + min(f(0.4) + :math.sqrt(dx * dx + dz * dz) / 80.0 - 1.0, 10.0), z}
        },
        else: state

    state =
      if target_distance(state) < 100.0 or target_distance(state) > 22_500.0,
        do: circle(state, env),
        else: state

    if distance(player.position, state.flight.position) < 4096.0 and visible?(env, player) do
      state = %{state | charge: state.charge + 1}

      if state.charge >= 5 and angle(state, player) >= 0.0 and angle(state, player) < 10.0 do
        head = elem(state.flight.parts, 0)

        start =
          add(
            head,
            add(
              scale(view(state.head_yaw, state.pitch), -1.0),
              {0.0, head_height() / 2.0 + 0.5, 0.0}
            )
          )

        aim = add(player.position, {0.0, player.height / 2.0, 0.0})

        state = %{
          state
          | effects: state.effects ++ [{:fireball, start, normalize(sub(aim, start))}]
        }

        set(state, 0)
      else
        state
      end
    else
      %{state | charge: max(0, state.charge - 1)}
    end
  end

  defp decide(%{phase: 2} = state, env) do
    if retarget?(state, env) do
      state =
        if state.path in [nil, []] do
          player = nearest(env, env.podium, :infinity, false)

          point =
            if player do
              {x, _, z} = player.position
              {a, _, b} = normalize({x, 0.0, z})
              {-a * 40.0, 105.0, -b * 40.0}
            else
              {40.0, elem(env.podium, 1), 0.0}
            end

          route(
            state,
            env,
            closest(state, env),
            Paths.closest(env.graph, point, env.crystals),
            env.podium
          )
        else
          state
        end

      state = navigate(state)
      if state.path == [], do: set(state, 3), else: state
    else
      state
    end
  end

  defp decide(%{phase: 3} = state, env) do
    state = %{state | target: state.target || bottom(env.podium)}
    if target_distance(state) < 1.0, do: set(%{state | flames: 0}, 6), else: state
  end

  defp decide(%{phase: 4, first: false, path: path} = state, env) when path != nil do
    if distance(state.flight.position, center(env.podium)) >= 100.0,
      do: set(state, 0),
      else: state
  end

  defp decide(%{phase: 4} = state, env) do
    {x, _, z} = head_look(state, env.podium)
    target = Paths.closest(env.graph, {-x * 40.0, 105.0, -z * 40.0}, env.crystals)
    target = ring(target, env.crystals != nil and env.crystals > 0)
    %{(route(state, env, closest(state, env), target) |> navigate()) | first: false}
  end

  defp decide(%{phase: 5} = state, env) do
    state = %{state | ticks: state.ticks + 1}

    cond do
      state.ticks >= 200 ->
        set(state, if(state.flames >= 4, do: 4, else: 6))

      state.ticks == 10 ->
        {hx, hy, hz} = head = elem(state.flight.parts, 0)
        {dx, _, dz} = normalize(sub(head, state.flight.position) |> horizontal())
        x = hx + dx * 2.5
        z = hz + dz * 2.5
        initial = hy + head_height() / 2.0
        # Everything above the dimension's top is air. Skip it arithmetically,
        # retaining the fractional sample and the native empty-column fallback.
        first = initial - max(0, ceil(initial - Map.get(env, :max_y, 320)))
        y = floor(flame_floor(env, x, first, z, initial)) + 1
        %{state | flame_live: true, effects: state.effects ++ [{:flame, {x, y * 1.0, z}}]}

      true ->
        state
    end
  end

  defp decide(%{phase: 6} = state, env) do
    state = %{state | ticks: state.ticks + 1}
    player = nearest(env, state.flight.position, 20.0, true, 10.0)

    cond do
      player != nil and state.ticks > 25 ->
        set(state, 7)

      player != nil ->
        scan_turn(state, player)

      state.ticks >= 100 ->
        player = nearest(env, state.flight.position, 150.0, true)
        if player, do: %{set(state, 8) | target: player.position}, else: set(state, 4)

      true ->
        state
    end
  end

  defp decide(%{phase: 7} = state, _env) do
    if state.ticks >= 40, do: set(state, 5), else: %{state | ticks: state.ticks + 1}
  end

  defp decide(%{phase: 8} = state, env) do
    cond do
      state.target == nil or state.ticks >= 10 ->
        set(state, 0)

      true ->
        ticks = state.ticks + if(state.ticks > 0, do: 1, else: 0)
        %{state | ticks: ticks + if(retarget?(state, env), do: 1, else: 0)}
    end
  end

  defp decide(%{phase: 9} = state, env) do
    state = %{state | target: state.target || bottom(env.podium), ticks: state.ticks + 1}
    health = if retarget?(state, env), do: 0.0, else: 1.0
    %{state | effects: state.effects ++ [{:health, health}]}
  end

  defp decide(%{phase: 10} = state, _env),
    do: %{state | target: state.target || state.flight.position}

  defp choose_strafe(state, env) do
    player = nearest(env, env.podium, :infinity, false)

    if player do
      {draw, state} =
        draw(state, trunc(distance(center(env.podium), player.position) / 512.0 + 2.0))

      {attack, state} =
        if draw == 0,
          do: {true, state},
          else: draw(state, (env.crystals || 0) + 2) |> then(fn {n, s} -> {n == 0, s} end)

      if attack, do: strafe(state, player, env), else: circle(state, env)
    else
      circle(state, env)
    end
  end

  defp circle(state, env) do
    state =
      if state.path in [nil, []] do
        current = closest(state, env)
        {n, state} = draw(state, 8)

        clockwise =
          if n == 0, do: not state.clockwise[state.phase], else: state.clockwise[state.phase]

        target = current + if(n == 0, do: 6, else: 0) + if(clockwise, do: 1, else: -1)

        outer =
          env.crystals != nil and
            if(state.phase == 0, do: env.crystals >= 0, else: env.crystals > 0)

        state = put_in(state.clockwise[state.phase], clockwise)
        route(state, env, current, ring(target, outer))
      else
        state
      end

    navigate(state)
  end

  defp ring(index, true), do: Integer.mod(index, 12)
  defp ring(index, false), do: (index - 12 &&& 7) + 12
  defp closest(state, env), do: Paths.closest(env.graph, state.flight.position, env.crystals)

  defp route(state, env, from, to, final \\ nil) do
    path = Paths.find(env.graph, from, to, env.crystals, final)
    %{state | path: if(path, do: Enum.drop(path, 1))}
  end

  defp navigate(%{path: [{x, y, z} | remaining]} = state) do
    {offset, random} = Random.float(state.random)

    %{
      state
      | target: {x * 1.0, f(y + f(offset * 20.0)), z * 1.0},
        path: remaining,
        random: random
    }
  end

  defp navigate(state), do: state
  defp target_distance(%{target: nil}), do: 0.0
  defp target_distance(state), do: distance(state.target, state.flight.position)

  defp retarget?(state, env),
    do:
      target_distance(state) < 100.0 or target_distance(state) > 22_500.0 or
        Map.get(env, :collision, false)

  defp draw(state, bound) do
    {n, random} = Random.int(state.random, bound)
    {n, %{state | random: random}}
  end

  defp nearest(env, at, range, sight, vertical \\ :infinity) do
    env.players
    |> Enum.filter(fn p ->
      (range == :infinity or distance(p.position, at) <= range * range) and
        (vertical == :infinity or abs(elem(p.position, 1) - elem(at, 1)) <= vertical) and
        (not sight or visible?(env, p))
    end)
    |> Enum.min_by(&distance(&1.position, at), fn -> nil end)
  end

  defp visible?(env, player), do: env.visible.(player)

  defp angle(state, player) do
    aim = normalize(sub(player.position, state.flight.position) |> horizontal())
    rad = f(state.flight.yaw * @rad)
    direction = normalize({Trig.sin(rad), 0.0, -Trig.cos(rad)})
    f(f(:math.acos(f(dot(direction, aim))) * 180.0 / @pi) + 0.5)
  end

  defp scan_turn(state, player) do
    if angle(state, player) < 0.0 or angle(state, player) > 10.0 do
      {dx, _, dz} = sub(player.position, elem(state.flight.parts, 0))

      delta =
        Mth.clamp(
          wrap_double(180.0 - Mth.atan2(dx, dz) * 180.0 / @pi - state.flight.yaw),
          -100.0,
          100.0
        )

      speed = f(f(:math.sqrt(dx * dx + dz * dz)) + 1.0)

      turn =
        f(f(state.flight.turn * f(0.8)) + f(f(delta) * f(f(f(0.7) / min(speed, 40.0)) / speed)))

      %{state | flight: %{state.flight | turn: turn, yaw: f(state.flight.yaw + turn)}}
    else
      state
    end
  end

  defp head_look(%{flight: flight, head_yaw: head_yaw}, podium) do
    distance = max(f(f(:math.sqrt(distance(center(podium), flight.position))) / 4.0), 1.0)
    pitch = f(f(-f(6.0 / distance) * 1.5) * 5.0)
    view(head_yaw, pitch)
  end

  defp view(yaw, pitch) do
    x = f(pitch * @rad)
    y = f(-yaw * @rad)
    {f(Trig.sin(y) * Trig.cos(x)), -Trig.sin(x), f(Trig.cos(y) * Trig.cos(x))}
  end

  defp flame_floor(_env, _x, y, _z, initial) when y < 0.0, do: initial

  defp flame_floor(env, x, y, z, initial) do
    if env.solid.({floor(x), floor(y), floor(z)}),
      do: y,
      else: flame_floor(env, x, y - 1.0, z, initial)
  end

  defp head_height, do: Facts.parts() |> hd() |> elem(2)
  defp bottom({x, y, z}), do: {x + 0.5, y * 1.0, z + 0.5}
  defp center({x, y, z}), do: {x + 0.5, y + 0.5, z + 0.5}
  defp horizontal({x, _, z}), do: {x, 0.0, z}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp sub({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
  defp scale({x, y, z}, n), do: {x * n, y * n, z * n}
  defp dot({x, y, z}, {a, b, c}), do: x * a + y * b + z * c
  defp distance(a, b), do: dot(sub(a, b), sub(a, b))

  defp normalize(v) do
    length = :math.sqrt(dot(v, v))

    if length < 1.0e-5,
      do: {0.0, 0.0, 0.0},
      else: then(v, fn {x, y, z} -> {x / length, y / length, z / length} end)
  end

  defp wrap_double(value) do
    value = :math.fmod(value, 360.0)
    value = if value >= 180.0, do: value - 360.0, else: value
    if value < -180.0, do: value + 360.0, else: value
  end

  defp f(v), do: Float32.round(v)
end
