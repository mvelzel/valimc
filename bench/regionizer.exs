# Group processes and the regionizer (VMC-077j): what merging and splitting
# sections between groups costs, what one tick of a group of N sections
# costs, and whether two groups far apart tick in parallel.
#
#     VALIMC_PORT=0 MIX_ENV=bench mix run bench/regionizer.exs OUT.json [ITEMS]
#
# A flat world in a temporary folder; every section holds ITEMS dropped items
# (default 64) and an edited block per chunk, and ticks with every chunk
# simulated. Groups tick only when stepped (`:manual`), so tick times are the
# pipeline's alone. The regionizer merges each row of sections into one group.
alias Valimc.Protocol.ItemStack
alias Valimc.World
alias Valimc.World.{Region, Regionizer}

[output | rest] = System.argv()
items = rest |> Enum.at(0, "64") |> String.to_integer()
base = Path.join(System.tmp_dir!(), "valimc-bench-groups-#{System.unique_integer([:positive])}")
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :region_ticks, :manual)
Application.put_env(:valimc, :region_unload_delay_ms, 600_000)
size = Valimc.Data.Grid.region_size()
stone = Valimc.Data.Blocks.default_state("stone")
median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end

wait = fn condition, timeout ->
  deadline = System.monotonic_time(:millisecond) + timeout

  Stream.repeatedly(fn ->
    cond do
      condition.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> raise "condition not reached"
      true -> Process.sleep(5) && nil
    end
  end)
  |> Enum.find(& &1)
end

# A section with content, once generated: an edited block per chunk and
# `items` items, all of its chunks simulated.
fill = fn key ->
  {:ok, owner} = World.owner(Valimc.Data.Grid.section(:overworld, key, :section))
  {rx, rz} = key
  chunks = for x <- 0..(size - 1), z <- 0..(size - 1), do: {rx * size + x, rz * size + z}
  {pid, _} = owner
  Region.ticket(pid, key, :forced, chunks)
  :ok = Region.await_chunks(owner, chunks, 120_000)

  edits =
    for cx <- 0..(size - 1), cz <- 0..(size - 1), into: %{} do
      {{(rx * size + cx) * 16 + 8, 70, (rz * size + cz) * 16 + 8}, stone}
    end

  {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
  {:ok, _} = Region.set_blocks(owner, observed.fence, edits)

  for n <- 1..items//1 do
    position = {rx * size * 16 + rem(n, 120) + 0.5, 64.0, rz * size * 16 + div(n, 120) + 0.5}
    {:ok, _} = Region.create_item(owner, ItemStack.new("stone", 1), position)
  end

  owner
end

group_of = fn key ->
  elem(elem(World.owner(Valimc.Data.Grid.section(:overworld, key, :section)), 1), 0)
end

# A row of `n` sections from `{x, z}`: the regionizer makes them one group.
row = fn {x, z}, n ->
  keys = for dx <- 0..(n - 1), do: {x + dx, z}
  Enum.each(keys, fill)
  wait.(fn -> keys |> Enum.map(group_of) |> Enum.uniq() |> length() == 1 end, 60_000)
  keys
end

# Until no section of the group has an item plan in flight: items do not
# move while one runs, and a step call runs its ticks without reading its
# mailbox.
quiet = fn {pid, _} ->
  wait.(
    fn ->
      :sys.get_state(pid).sections
      |> Enum.all?(fn {_, s} -> not Valimc.World.RegionData.planning?(s.resource) end)
    end,
    60_000
  )
end

# Tick time of a group of n sections: 10 samples of 5 steps, per step.
tick_time = fn keys ->
  {:ok, owner} = World.owner(Valimc.Data.Grid.section(:overworld, hd(keys), :section))
  quiet.(owner)
  {:ok, _} = Region.step(owner, 5)

  samples =
    for _ <- 1..10 do
      quiet.(owner)
      {micros, {:ok, _}} = :timer.tc(fn -> Region.step(owner, 5) end)
      micros / 5
    end

  median.(samples)
end

ticks =
  for {n, i} <- Enum.with_index([1, 4, 16, 64]) do
    keys = row.({100_000 + i * 200, 3000}, n)
    us = tick_time.(keys)
    IO.puts("group of #{n} sections: #{Float.round(us / 1000, 2)} ms per tick")
    %{sections: n, tick_us: us}
  end

# Merge and split pauses: a section joins a group of n and leaves it again.
# The source group pauses for the handoff; the adopting group for the
# adoption and one full collection (measured as the two calls behind them).
pauses =
  for {n, i} <- Enum.with_index([1, 8, 32]) do
    origin = {110_000 + i * 200, 3000}
    keys = row.(origin, n)
    group = group_of.(hd(keys))

    samples =
      for round <- 1..5 do
        # A lone section far off, then handed to the group (a merge) and split out again.
        lone = {elem(origin, 0) + 100 + round * 10, 3000}
        fill.(lone)
        source = group_of.(lone)
        {merge_us, {:ok, _}} = :timer.tc(fn -> Region.hand_over(source, group) end)
        {adopt_us, _} = :timer.tc(fn -> {Region.sections(group), Region.sections(group)} end)
        wait.(fn -> group_of.(lone) == group end, 30_000)
        {split_us, {:ok, new, _}} = :timer.tc(fn -> Region.split(group, :overworld, [lone]) end)
        wait.(fn -> group_of.(lone) == new end, 30_000)
        {merge_us, adopt_us, split_us}
      end

    merge = median.(Enum.map(samples, &elem(&1, 0)))
    adopt = median.(Enum.map(samples, &elem(&1, 1)))
    split = median.(Enum.map(samples, &elem(&1, 2)))

    IO.puts(
      "group of #{n}: merge #{round(merge)} µs (adopter #{round(adopt)} µs), split #{round(split)} µs"
    )

    %{group: n, merge_us: merge, adopt_us: adopt, split_us: split}
  end

# Two groups of 16 far apart, stepped one after the other and at once.
a = row.({130_000, 3000}, 16)
b = row.({130_000 + 400, 3000}, 16)
{:ok, oa} = World.owner(Valimc.Data.Grid.section(:overworld, hd(a), :section))
{:ok, ob} = World.owner(Valimc.Data.Grid.section(:overworld, hd(b), :section))
step = fn owner -> {:ok, _} = Region.step(owner, 20) end
_ = {quiet.(oa), quiet.(ob), step.(oa), step.(ob)}

sequential =
  median.(for _ <- 1..5, do: elem(:timer.tc(fn -> step.(oa) && step.(ob) end), 0))

parallel =
  median.(
    for _ <- 1..5 do
      {us, _} =
        :timer.tc(fn ->
          [Task.async(fn -> step.(oa) end), Task.async(fn -> step.(ob) end)]
          |> Task.await_many(60_000)
        end)

      us
    end
  )

IO.puts(
  "two groups of 16, 20 ticks each: one after the other #{round(sequential / 1000)} ms, " <>
    "at once #{round(parallel / 1000)} ms (#{Float.round(sequential / parallel, 2)} ×)"
)

groups = Regionizer.groups(:overworld) |> map_size()
{load, _} = System.cmd("uptime", [])
File.rm_rf(base)

File.write!(
  output,
  JSON.encode!(%{
    items_per_section: items,
    ticks: ticks,
    pauses: pauses,
    parallel: %{sequential_us: sequential, parallel_us: parallel},
    groups: groups,
    schedulers: System.schedulers_online(),
    uptime: String.trim(load),
    revision: elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0) |> String.trim()
  })
)
