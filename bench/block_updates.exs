# Block updates (VMC-077m): the engine's update throughput over a region's store,
# one NIF run per batch of changes (what a region commit makes) against one run
# per changed position (the per-position path). Workloads: a 16 x 16 stone layer
# set on a floor (each change runs six neighbour and six shape updates and nothing
# reacts) and a 64-wire line placed beside a redstone block (power spreads along
# it). The store is not changed by a run, so every repetition sees the same cells.
# Each workload runs 200 times; the median and fastest repetitions are kept, as a
# loaded host preempts some of them.
#   MIX_ENV=bench python3 scripts/heavy.py mix run --no-start bench/block_updates.exs OUT.json
alias Valimc.Block.Rules
alias Valimc.Registry.Blocks
alias Valimc.World.Blocks, as: Store

[output] = System.argv()
Rules.native()
{:ok, store} = Store.new({0, 0})

{stone, wire, block} =
  {Blocks.default_state("stone"), Blocks.default_state("redstone_wire"),
   Blocks.default_state("redstone_block")}

y = 100

layer = for x <- 8..23, z <- 8..23, into: %{}, do: {{x, y, z}, stone}
line = Map.new(1..64, &{{8 + &1, y, 40}, wire}) |> Map.put({8, y, 40}, block)
floor = for {{x, _, z}, _} <- Map.merge(layer, line), into: %{}, do: {{x, y - 1, z}, stone}
:ok = Store.put(store, floor)

workloads = %{"stone layer (256 changes)" => layer, "wire line (65 changes)" => line}

time = fn runs ->
  for _ <- 1..5, run <- runs, do: run.()

  samples =
    for _ <- 1..200 do
      :timer.tc(fn -> Enum.sum(for run <- runs, do: run.()) end)
    end

  micros = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  {Enum.at(micros, 100), hd(micros), samples |> hd() |> elem(1), micros}
end

results =
  for {name, changes} <- Enum.sort(workloads), mode <- [:batched, :per_position] do
    :ok = Store.put(store, changes)
    previous = Map.new(changes, fn {pos, _} -> {pos, 0} end)

    runs =
      case mode do
        :batched ->
          [fn -> Rules.run(store, previous, [], []).updates end]

        :per_position ->
          for {pos, old} <- previous,
              do: fn -> Rules.run(store, %{pos => old}, [], []).updates end
      end

    {micros, fastest, updates, samples} = time.(runs)
    :ok = Store.put(store, previous)

    row = %{
      workload: name,
      mode: mode,
      changes: map_size(changes),
      calls: length(runs),
      median_micros: micros,
      fastest_micros: fastest,
      updates: updates,
      updates_per_second: round(updates / micros * 1_000_000),
      micros_per_change: Float.round(micros / map_size(changes), 2),
      samples: samples
    }

    IO.puts(
      "#{String.pad_trailing(name, 26)} #{String.pad_trailing(to_string(mode), 13)} " <>
        "median #{micros} us (fastest #{fastest}), #{updates} updates, " <>
        "#{row.updates_per_second} updates/s, #{row.micros_per_change} us/change"
    )

    row
  end

File.write!(
  output,
  JSON.encode!(%{
    system: :erlang.system_info(:system_version),
    load: :os.cmd(~c"uptime") |> to_string() |> String.trim(),
    results: results
  })
)
