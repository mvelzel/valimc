defmodule Valimc.World.TraderSpawner do
  @moduledoc """
  `WanderingTraderSpawner` (VMC-044a4), the overworld's, run by a group
  after its natural spawns while `spawnWanderingTraders` holds: every 1200
  ticks its spawn delay (24000 at first) runs down by 1200; when it is up it
  starts again and, with its chance (25, rising by 25 to 75 each time it
  fails, back to 25 when a trader spawns), it tries: one time in ten, near a
  random player of the group, a trader spawns by the meeting point within
  48 blocks of it (else the player), at one of ten random spots within 48
  blocks on the ground, where it has room and the biome allows it. It wanders
  toward that point, keeps within 16 blocks of it and goes after 48000
  ticks. The chance and the delay draw on the spawner's own random; the
  player and the trader's facing on the group's level random.

  Vanilla's delay and chance are the level's, saved with it; here each
  group counts its own and starts afresh when it does. Its two trader
  llamas are not modelled yet (llamas are VMC-043's).
  """
  alias Valimc.AI.Pois
  alias Valimc.Data.{BlockFacts, EntityTypes, Float32, Grid, JavaRandom}
  alias Valimc.Entity.{Body, Store}

  @tick_delay 1200
  @spawn_delay 24_000
  @trader "minecraft:wandering_trader"
  @meeting "minecraft:meeting"
  @without Valimc.Protocol.Data.tags()["minecraft:worldgen/biome"][
             "minecraft:without_wandering_trader_spawns"
           ]
           |> MapSet.new()

  @doc "A group's fresh spawner state."
  def new,
    do: %{tick: @tick_delay, delay: @spawn_delay, chance: 25, random: JavaRandom.create()}

  @doc """
  One tick of the spawner for `group` with the level `random`: `{state,
  random, [{section key, record}]}`.
  """
  def tick(group, random) do
    state = Map.get(group.spawning, :traders) || new()

    if group.dimension != :overworld or not Valimc.World.GameRules.get(:spawn_wandering_traders) do
      {state, random, []}
    else
      state = %{state | tick: state.tick - 1}

      if state.tick > 0 do
        {state, random, []}
      else
        state = %{state | tick: @tick_delay, delay: state.delay - @tick_delay}

        if state.delay > 0 do
          {state, random, []}
        else
          chance = state.chance
          state = %{state | delay: @spawn_delay, chance: min(max(chance + 25, 25), 75)}
          {n, own} = JavaRandom.next_int(state.random, 100)
          state = %{state | random: own}

          if n <= chance do
            {spawned, made, state, random} = try_spawn(group, state, random)
            {if(spawned, do: %{state | chance: 25}, else: state), random, made}
          else
            {state, random, []}
          end
        end
      end
    end
  end

  # `spawn`: true when a trader came, or there is no player.
  defp try_spawn(%{players: []}, state, random), do: {true, [], state, random}

  defp try_spawn(group, state, random) do
    {n, random} = JavaRandom.next_int(random, length(group.players))
    {px, py, pz, _, _} = Enum.at(group.players, n)
    {one, own} = JavaRandom.next_int(state.random, 10)
    state = %{state | random: own}

    if one != 0 do
      {false, [], state, random}
    else
      player = {floor(px), floor(py), floor(pz)}
      world = world(group)

      reference =
        case Pois.in_range(world, [@meeting], player, 48, :any) do
          [{_, pos} | _] -> pos
          [] -> player
        end

      {spot, state} = spot(group, state, reference, 48, 10)

      cond do
        spot == nil or not room?(world, spot) ->
          {false, [], state, random}

        biome_without?(group, spot) ->
          {false, [], state, random}

        true ->
          {f, random} = JavaRandom.next_float(random)
          yaw = wrap(Float32.round(f * 360.0))
          {x, _, z} = spot
          record = trader(spot, yaw, reference)
          {true, [{Grid.region_key(Grid.chunk_key(x, z)), record}], state, random}
      end
    end
  end

  # `findSpawnPositionNear`: ten tries within `radius`, each on the spawn
  # heightmap where a trader may stand.
  defp spot(_group, state, _reference, _radius, 0), do: {nil, state}

  defp spot(group, state, {rx, _, rz} = reference, radius, tries) do
    {a, own} = JavaRandom.next_int(state.random, radius * 2)
    {b, own} = JavaRandom.next_int(own, radius * 2)
    state = %{state | random: own}
    {x, z} = {rx + a - radius, rz + b - radius}
    [region | siblings] = group.stores
    kind = EntityTypes.id(@trader)

    case Valimc.Native.spawn_position_ok(
           region,
           siblings,
           group.absent,
           group.environment,
           kind,
           {x, nil, z},
           0
         ) do
      {:ok, {true, true, y}} -> {{x, y, z}, state}
      _ -> spot(group, state, reference, radius, tries - 1)
    end
  end

  # `hasEnoughSpace`: no block from the spot to one across, two up has a
  # collision shape.
  defp room?(world, {x, y, z}) do
    for dx <- 0..1, dy <- 0..2, dz <- 0..1, reduce: true do
      acc ->
        acc and
          case Valimc.AI.World.block(world, {x + dx, y + dy, z + dz}) do
            nil -> false
            state -> empty?(BlockFacts.collision(state))
          end
    end
  end

  defp empty?({:fixed, %{boxes: []}}), do: true
  defp empty?({:context, "minecraft:powder_snow"}), do: true
  defp empty?(_shape), do: false

  defp biome_without?(group, pos) do
    case Valimc.World.View.biome(Valimc.World.View.new(group.dimension), pos) do
      {:ok, id} ->
        MapSet.member?(@without, id)

      :error ->
        true
    end
  end

  defp world(group) do
    view = Valimc.World.View.new(group.dimension)

    %Valimc.AI.World{
      read: &Valimc.World.View.block(view, &1),
      find: &find(view, &1, &2),
      pois: Pois.merge(for {_, r} <- group.sections, do: r.poi_claims)
    }
  end

  defp find(view, {x0, y0, z0, x1, y1, z1}, states) do
    list = MapSet.to_list(states)

    for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
        cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
        {{x, y, z}, state} <- Valimc.World.View.find(view, {cx, cz}, list),
        x in x0..x1 and y in y0..y1 and z in z0..z1,
        do: {{x, y, z}, state}
  end

  # `Mth.wrapDegrees`.
  defp wrap(degrees) do
    d = :math.fmod(degrees, 360.0)
    d = if d >= 180.0, do: d - 360.0, else: d
    Float32.round(if d < -180.0, do: d + 360.0, else: d)
  end

  # `EntityType.spawn(level, pos, EVENT)`: at the spot's bottom centre,
  # facing its drawn way, with its despawn delay, wander target and home.
  defp trader({x, y, z}, yaw, reference) do
    {:ok, body} = Body.spawned(@trader, :event)

    body = %{
      body
      | yaw: yaw,
        head_yaw: yaw,
        data: %{body.data | despawn_delay: 48_000, wander_target: reference},
        mob: %{body.mob | home: {reference, 16}}
    }

    Store.body_record(body, :crypto.strong_rand_bytes(16), {x + 0.5, y * 1.0, z + 0.5})
  end
end
