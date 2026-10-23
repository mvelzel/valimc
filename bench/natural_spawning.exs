# VMC-042a: a group's natural spawning tick against the 50 ms tick. Nine
# sections (24 x 24 chunks) of stone with three cave layers under a grass
# surface, lit by the light engine, one player at the centre at night: every
# tick runs `World.Spawning.plan/1` (the mob list, one spawn-kernel call with
# the despawn checks, the records of what spawned) and the spawned mobs join
# the counts, so the caps fill and the tick reaches its steady state.
# A second argument places that many zombies across the sections first (they
# count and are checked for despawning every tick).
# Usage: MIX_ENV=bench mix run --no-start bench/natural_spawning.exs [ticks] [zombies]
alias Valimc.Data.{Blocks, Grid}
alias Valimc.Entity.Store
alias Valimc.Native
alias Valimc.World.Spawning

[ticks, zombies] =
  case System.argv() do
    [] -> [400, 0]
    [t] -> [String.to_integer(t), 0]
    [t, z | _] -> [String.to_integer(t), String.to_integer(z)]
  end

Spawning.install!()
size = Grid.region_size()
state = &Blocks.default_state/1
caves = Enum.concat([-40..-37, -10..-7, 20..23])

layers =
  for y <- -64..319, into: <<>> do
    s =
      cond do
        y == -64 -> state.("bedrock")
        y in caves -> state.("air")
        y < 60 -> state.("stone")
        y < 63 -> state.("dirt")
        y == 63 -> state.("grass_block")
        true -> state.("air")
      end

    <<s::16>>
  end

keys = for x <- -1..1, z <- -1..1, do: {x, z}

sections =
  Map.new(keys, fn {rx, rz} = key ->
    {:ok, ref} = Native.region_new(rx * size, rz * size, size, layers, 1_073_741_824)
    :ok = Native.light_init(ref, [])

    chunks =
      for x <- 0..(size - 1),
          z <- 0..(size - 1),
          into: MapSet.new(),
          do: {rx * size + x, rz * size + z}

    {key, %{ref: ref, tickets: %{simulated: chunks}, entities: %{store: Store.new()}}}
  end)

# Zombies on the surface, spread over the nine sections.
{:ok, zombie} = Valimc.Entity.Body.new("minecraft:zombie")

sections =
  Enum.reduce(0..(zombies - 1)//1, sections, fn n, acc ->
    {x, z} = {-128 + rem(n * 37, 384) + 0.5, -128 + rem(n * 91, 384) + 0.5}
    key = Grid.region_key(Grid.chunk_key(x, z))
    record = Store.body_record(zombie, <<n + 1::128>>, {x, 64.0, z})

    Map.update!(acc, key, fn s ->
      {:ok, store, _} = Store.create_record(s.entities.store, key, record)
      put_in(s.entities.store, store)
    end)
  end)

env = %{
  dimension: "minecraft:overworld",
  zoom_seed: 0,
  seed: 42,
  sea_level: 63,
  max_y: 319,
  darken: 11,
  thundering: false,
  difficulty: 2,
  slime_chance: 0.0,
  border: {-29_999_984.0, -29_999_984.0, 29_999_984.0, 29_999_984.0}
}

players = [{64.5, 64.0, 64.5, false, false}]

step = fn sections, spawning, t ->
  group = %{
    sections: sections,
    stores: for({_, s} <- sections, do: s.ref),
    absent: [],
    players: players,
    spawning: spawning,
    environment: env,
    game_time: t
  }

  {time, {spawning, plan}} = :timer.tc(fn -> Spawning.plan(group) end)

  sections =
    Enum.reduce(plan, sections, fn {key, {records, discards, _}}, acc ->
      Map.update!(acc, key, fn s ->
        store =
          Enum.reduce(records, s.entities.store, fn r, st ->
            case Store.create_record(st, key, r) do
              {:ok, st, _} -> st
              _ -> st
            end
          end)

        store =
          Enum.reduce(discards, store, fn id, st ->
            {:ok, st} = Store.remove(st, st.epoch, id, st.entries[id].revision)
            st
          end)

        put_in(s.entities.store, store)
      end)
    end)

  {sections, spawning, time}
end

{sections, _, samples} =
  Enum.reduce(1..ticks, {sections, Spawning.new(), []}, fn t, {sections, spawning, acc} ->
    {sections, spawning, time} = step.(sections, spawning, t)
    {sections, spawning, [time | acc]}
  end)

mobs = Enum.sum(for {_, s} <- sections, do: map_size(s.entities.store.entries))
samples = Enum.reverse(samples)
median = fn values -> values |> Enum.sort() |> Enum.at(div(length(values), 2)) end
early = median.(Enum.take(samples, 50))
steady = median.(Enum.drop(samples, div(ticks, 2)))
worst = Enum.max(Enum.drop(samples, 5))
p99 = samples |> Enum.drop(5) |> Enum.sort() |> Enum.at(trunc((ticks - 5) * 0.99))

IO.puts(
  "natural spawning, 9 sections, one player at night, #{zombies} zombies placed: #{mobs} mobs after #{ticks} ticks; " <>
    "median #{Float.round(early / 1000, 2)} ms a tick while the caps fill, " <>
    "#{Float.round(steady / 1000, 2)} ms at the caps, 99th percentile #{Float.round(p99 / 1000, 2)} ms, worst #{Float.round(worst / 1000, 2)} ms " <>
    "(#{Float.round(steady / 50_000 * 100, 1)}% of a 50 ms tick at the caps)"
)
