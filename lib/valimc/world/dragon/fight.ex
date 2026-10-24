defmodule Valimc.World.Dragon.Fight do
  @moduledoc "Bounded End fight state and ritual effects, owned by the origin section (VMC-045a6)."
  alias Valimc.Data.JavaRandom

  defstruct dragon: nil,
            podium: nil,
            killed: false,
            previous_kill: false,
            gateways: [],
            stage: nil,
            time: 0,
            crystals: [],
            alive_crystals: 0,
            initialized: false,
            scan: 0,
            missing: 0

  @doc "A fresh world's twenty seed-shuffled gateway indices, consumed from the end."
  def new(seed) do
    {gateways, _} =
      Enum.reduce(20..2//-1, {Enum.to_list(0..19), JavaRandom.new(seed)}, fn bound, {list, rng} ->
        {index, rng} = JavaRandom.next_int(rng, bound)
        a = Enum.at(list, bound - 1)
        b = Enum.at(list, index)
        {list |> List.replace_at(index, a) |> List.replace_at(bound - 1, b), rng}
      end)

    %__MODULE__{gateways: gateways}
  end

  @doc "The generation kernel's spike descriptions; no second seed/geometry implementation."
  def spikes(seed) do
    {:ok, rows} = Valimc.Native.worldgen_end_spikes(seed)

    for {x, z, radius, height, guarded} <- rows,
        do: %{x: x, z: z, radius: radius, height: height, guarded: guarded}
  end

  @doc "The boss audience includes every alive player within the native 192-block sphere."
  def eligible?(%{alive: true, x: x, y: y, z: z}),
    do: x * x + (y - 128.0) * (y - 128.0) + z * z <= 192.0 * 192.0

  def eligible?(_), do: false

  @doc "Only the tracked dragon can complete the fight; repeated delivery has no effects."
  def complete(%__MODULE__{dragon: uuid, killed: false} = fight, uuid) when uuid != nil do
    {gateway, remaining} = List.pop_at(fight.gateways, -1)
    egg = if fight.previous_kill, do: [], else: [:egg]
    gates = if gateway == nil, do: [], else: [{:gateway, gateway(gateway)}]

    {%{fight | killed: true, previous_kill: true, gateways: remaining},
     [{:podium, true}] ++ gates ++ egg}
  end

  def complete(fight, _uuid), do: {fight, []}

  @doc "The gateway ring's coordinates, with Java's floor at the axes."
  def gateway(index) when index in 0..19 do
    angle = 2.0 * (-:math.pi() + :math.pi() / 20.0 * index)
    {floor(96.0 * :math.cos(angle)), 75, floor(96.0 * :math.sin(angle))}
  end

  @doc "All crystals intersecting each cardinal unit box are part of a new ritual."
  def try_respawn(%__MODULE__{killed: true, stage: nil, podium: {x, y, z}} = fight, crystals) do
    groups =
      for {dx, dz} <- [{0, -3}, {3, 0}, {0, 3}, {-3, 0}] do
        box = {x + dx, y + 1, z + dz, x + dx + 1, y + 2, z + dz + 1}
        for crystal <- crystals, intersects?(box, crystal.box), do: crystal.uuid
      end

    if Enum.any?(groups, &(&1 == [])) do
      {fight, []}
    else
      {%{fight | stage: :start, time: 0, crystals: List.flatten(groups)},
       [:clear_portal, {:podium, false}]}
    end
  end

  def try_respawn(fight, _crystals), do: {fight, []}

  @doc "A broken ritual crystal aborts immediately; other crystal callbacks leave it running."
  def crystal_destroyed(%__MODULE__{stage: stage} = fight, uuid) when stage != nil do
    if uuid in fight.crystals, do: abort(fight), else: {fight, []}
  end

  def crystal_destroyed(fight, _uuid), do: {fight, []}

  defp abort(fight),
    do: {%{fight | stage: nil, time: 0, crystals: []}, [:reset_spike_crystals, {:podium, true}]}

  @doc "One ritual tick; `live` is the set of currently owned crystal UUIDs."
  def ritual(%__MODULE__{stage: nil} = fight, _spikes, _live), do: {fight, []}

  def ritual(fight, spikes, live) do
    crystals = Enum.filter(fight.crystals, &MapSet.member?(live, &1))

    if crystals == [] do
      abort(fight)
    else
      ritual_step(%{fight | time: fight.time + 1}, fight.stage, fight.time, spikes, crystals)
    end
  end

  defp next(fight, stage), do: %{fight | stage: stage, time: 0}

  defp ritual_step(fight, :start, _time, _spikes, crystals),
    do: {next(fight, :preparing), [{:beam, crystals, {0, 128, 0}}]}

  defp ritual_step(fight, :preparing, 100, _spikes, _crystals),
    do: {next(fight, :pillars), []}

  defp ritual_step(fight, :preparing, time, _spikes, _crystals) do
    effects =
      if time in [0, 50, 51, 52] or time >= 95, do: [{:event, 3001, {0, 128, 0}}], else: []

    {fight, effects}
  end

  defp ritual_step(fight, :pillars, time, spikes, crystals) do
    case {rem(time, 40), Enum.at(spikes, div(time, 40))} do
      {0, nil} ->
        {next(fight, :summoning), []}

      {0, spike} ->
        {fight, [{:beam, crystals, {spike.x, spike.height + 1, spike.z}}]}

      {39, spike} when spike != nil ->
        {fight, [{:pillar, spike}]}

      _ ->
        {fight, []}
    end
  end

  defp ritual_step(fight, :summoning, time, _spikes, crystals) when time >= 100 do
    {%{fight | stage: nil, time: 0, killed: false, crystals: [], dragon: nil},
     [:spawn_dragon, :reset_spike_crystals] ++ Enum.map(crystals, &{:ritual_explode, &1})}
  end

  defp ritual_step(fight, :summoning, time, _spikes, crystals) do
    effects =
      cond do
        time == 0 -> [{:beam, crystals, {0, 128, 0}}]
        time < 5 or time >= 80 -> [{:event, 3001, {0, 128, 0}}]
        true -> []
      end

    {fight, effects}
  end

  defp intersects?({a, b, c, d, e, f}, {g, h, i, j, k, l}),
    do: a < j and d > g and b < k and e > h and c < l and f > i
end
