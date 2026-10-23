# VMC-015i: an owner's mob phase for several hundred zombies on one floor —
# one physics-kernel call (travel, collision, fluids, climbing, pushing), the
# living rules and the store's steps — against the 50 ms tick. The zombies
# stand a block apart, walking toward points across the floor, so they push
# each other. Usage: MIX_ENV=bench mix run bench/mob_ticks.exs [ticks]
alias Valimc.Entity.{Body, MobMotion, MobTicks, Store}

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

  # Each tick the AI's place: every zombie walks toward the far corner.
  steer = fn store ->
    entries =
      Map.new(store.entries, fn {id, e} ->
        motion = MobMotion.move_to(e.body.mob.motion, {40.5, 64.0, 40.5}, 1.0)
        {id, put_in(e.body.mob.motion, motion)}
      end)

    %{store | entries: entries}
  end

  tick = fn store ->
    store = steer.(store)
    mobs = Enum.sort(store.entries)
    {kernel, steps} = :timer.tc(fn -> MobTicks.steps(view, mobs, [], nil) end)

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
      "(kernel and living rules #{Float.round(kernel / 1000, 2)} ms, store steps " <>
      "#{Float.round(applied / 1000, 2)} ms; #{Float.round(total / count, 1)} µs a mob; " <>
      "#{Float.round(total / 50_000 * 100, 1)}% of a 50 ms tick)"
  )

  %{count: count, total_us: total, kernel_us: kernel, steps_us: applied}
end

results = Enum.map([100, 300, 600], run)
File.mkdir_p!("bench/results")
File.write!("bench/results/mob-ticks.json", JSON.encode!(results))
