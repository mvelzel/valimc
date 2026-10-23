# VMC-015i, VMC-041a: an owner's mob phase for several hundred zombies on one
# floor — their AI, one physics-kernel call (travel, collision, fluids,
# climbing, pushing), the living rules and the store's steps — against the
# 50 ms tick. The zombies stand a block apart and chase a survival player at
# the floor's far corner, so they push each other. Usage: MIX_ENV=bench mix
# run bench/mob_ticks.exs [ticks]
alias Valimc.Entity.{Body, MobTicks, Store}

ticks = String.to_integer(List.first(System.argv()) || "60")
Valimc.Data.BlockFacts.install!()
stone = Valimc.Data.Blocks.default_state("stone")
air = Valimc.Data.Blocks.default_state("air")

# A 48 x 48 stone floor at y 63 with air above, as a supplied view.
view =
  {:states,
   for x <- 0..47, z <- 0..47, y <- 62..68, into: <<>> do
     <<x::signed-32, y::signed-32, z::signed-32, if(y == 63, do: stone, else: air)::16>>
   end}

run = fn count ->
  side = ceil(:math.sqrt(count))
  {:ok, zombie} = Body.new("minecraft:zombie")

  {store, _} =
    Enum.reduce(0..(count - 1), {Store.new(), 0}, fn n, {store, _} ->
      position = {8.5 + rem(n, side) * 1.0, 64.0, 8.5 + div(n, side) * 1.0}
      record = Store.body_record(zombie, <<n + 1::128>>, position)
      {:ok, store, _} = Store.create_record(store, {0, 0}, record)
      {store, n}
    end)

  # The player they chase, and the floor the AI reads.
  player = %{
    kind: :player,
    uuid: <<0::128>>,
    id: 0,
    x: 40.5,
    y: 64.0,
    z: 40.5,
    yaw: 0.0,
    pitch: 0.0,
    eye: 1.6200000047683716,
    width: 0.6000000238418579,
    height: 1.7999999523162842,
    mode: :survival,
    invulnerable: false,
    alive: true,
    crouching: false,
    invisible: false,
    armor_cover: 0.0,
    equipment: %{mainhand: nil, offhand: nil}
  }

  world = %Valimc.AI.World{
    read: fn {x, y, z} -> if x in 0..47 and z in 0..47 and y == 63, do: stone, else: air end,
    players: [player]
  }

  tick = fn store ->
    mobs = Enum.sort(store.entries)
    {kernel, steps} = :timer.tc(fn -> MobTicks.steps(view, mobs, world, nil) end)

    {applied, {:ok, store, _}} =
      :timer.tc(fn ->
        Enum.reduce(Enum.chunk_every(steps, 32), {:ok, store, []}, fn batch, {:ok, s, _} ->
          Store.advance(s, {0, 0}, s.epoch, batch)
        end)
      end)

    {store, kernel, applied}
  end

  # Warm up, then time each tick.
  {store, _, _} = Enum.reduce(1..5, {store, 0, 0}, fn _, {s, _, _} -> tick.(s) end)

  {_, samples} =
    Enum.reduce(1..ticks, {store, []}, fn _, {s, acc} ->
      {s, kernel, applied} = tick.(s)
      {s, [{kernel, applied} | acc]}
    end)

  median = fn values -> values |> Enum.sort() |> Enum.at(div(length(values), 2)) end
  kernel = median.(Enum.map(samples, &elem(&1, 0)))
  applied = median.(Enum.map(samples, &elem(&1, 1)))
  total = median.(Enum.map(samples, fn {k, a} -> k + a end))

  IO.puts(
    "#{count} zombies: #{Float.round(total / 1000, 2)} ms a tick " <>
      "(AI, kernel and living rules #{Float.round(kernel / 1000, 2)} ms, store steps " <>
      "#{Float.round(applied / 1000, 2)} ms; #{Float.round(total / count, 1)} µs a mob; " <>
      "#{Float.round(total / 50_000 * 100, 1)}% of a 50 ms tick)"
  )

  %{count: count, total_us: total, kernel_us: kernel, steps_us: applied}
end

counts =
  (System.get_env("MOB_COUNTS") || "100,300,600")
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)

results = Enum.map(counts, run)
File.mkdir_p!("bench/results")
File.write!("bench/results/mob-ticks.json", JSON.encode!(results))
