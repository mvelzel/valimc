# Published chunk snapshots (VMC-077p), matched across revisions: regions of
# generated terrain (seed 20261020, decorated) loaded as a region owner loads
# them (column images into the store, every chunk published into a fresh
# table), then edited. Per region: resident block memory, the store's
# sections and what its publication holds apart from them (section, height
# and biome binaries and the table's rows before; snapshot records and
# sections the store no longer shares after); after loading and after one
# edit in every chunk. Per committed batch: the republish of 1, 8 or 64 chunks
# with one changed block each, alone and with the write that changed them.
#
#   MIX_ENV=bench python3 scripts/heavy.py mix run --no-start bench/snapshot_publication.exs OUT.json
alias Valimc.World.{BlockSnapshot, Blocks, RegionGeneration}
alias Valimc.Worldgen.Scheduler

[output] = System.argv()
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, nil)
{:ok, _} = Application.ensure_all_started(:valimc)
handles? = function_exported?(Valimc.Native, :snapshot_resident, 2)

seed = 20_261_020

base =
  Path.join(System.tmp_dir!(), "valimc-bench-snapshots-#{System.unique_integer([:positive])}")

File.mkdir_p!(base)

:ok =
  Valimc.World.Spec.write(base, %{
    "type" => "vanilla",
    "seed" => seed,
    "features" => true,
    "settings" => Valimc.World.GenSettings.create("minecraft:normal", nil, seed, true)
  })

{:ok, _} = Scheduler.whereis(base, :overworld)
keys = for rz <- 0..1, rx <- 0..1, do: {rx, rz}

regions =
  for key <- keys do
    chunks = RegionGeneration.chunks_of(key)
    {:ok, fulls} = Scheduler.full_chunks(base, :overworld, chunks)
    {:ok, blocks} = Blocks.new(key)
    {:ok, _} = Blocks.put_columns(blocks, Map.new(fulls, &{{&1.x, &1.z}, &1.image}))
    table = :ets.new(:bench_publication, [:set, :public])
    :ok = BlockSnapshot.publish_chunks(table, blocks, chunks, 0)
    %{key: key, chunks: chunks, blocks: blocks, table: table}
  end

# Bytes of the binaries a term holds off the heap (refc, over 64 bytes; each
# section, height and biome binary is an allocation of its own).
off_heap = fn term ->
  walk = fn
    _, b when is_binary(b) and byte_size(b) > 64 -> :binary.referenced_byte_size(b)
    walk, t when is_tuple(t) -> t |> Tuple.to_list() |> Enum.map(&walk.(walk, &1)) |> Enum.sum()
    walk, l when is_list(l) -> l |> Enum.map(&walk.(walk, &1)) |> Enum.sum()
    _, _ -> 0
  end

  walk.(walk, term)
end

memory = fn %{blocks: blocks, table: table} ->
  :erlang.garbage_collect()
  rows = :ets.tab2list(table)
  ets = :ets.info(table, :memory) * :erlang.system_info(:wordsize)

  rust =
    if handles?,
      do: elem(Valimc.Native.snapshot_resident(blocks.ref, Enum.map(rows, &elem(&1, 1))), 1),
      else: elem(Valimc.Native.heap_bytes(blocks.ref), 1)

  binaries = off_heap.(rows)
  %{rust_bytes: rust, ets_bytes: ets, binary_bytes: binaries, total: rust + ets + binaries}
end

stone = Valimc.Registry.Blocks.default_state("stone")
glass = Valimc.Registry.Blocks.default_state("glass")

# One block per chunk at a fixed cell near the surface, toggled between two states.
edit = fn chunks, state ->
  Map.new(chunks, fn {cx, cz} -> {{cx * 16 + 7, 70, cz * 16 + 9}, state} end)
end

loaded = Enum.map(regions, memory)

edited =
  for region <- regions do
    :ok = Blocks.put(region.blocks, edit.(region.chunks, stone))
    :ok = BlockSnapshot.publish_chunks(region.table, region.blocks, region.chunks, 1)
    memory.(region)
  end

median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
region = hd(regions)

batches =
  for size <- [1, 8, 64] do
    chunks = Enum.take(region.chunks, size)
    rounds = div(4096, size)

    {publish, write_publish} =
      Enum.map_reduce(1..rounds, [], fn round, acc ->
        state = if rem(round, 2) == 0, do: stone, else: glass
        {write_us, :ok} = :timer.tc(fn -> Blocks.put(region.blocks, edit.(chunks, state)) end)

        {publish_us, :ok} =
          :timer.tc(fn ->
            BlockSnapshot.publish_chunks(region.table, region.blocks, chunks, round + 1)
          end)

        {publish_us, [write_us + publish_us | acc]}
      end)

    %{
      chunks: size,
      rounds: rounds,
      publish_median_us: median.(publish),
      write_and_publish_median_us: median.(write_publish)
    }
  end

result = %{
  revision: System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim(),
  handles: handles?,
  loaded: loaded,
  edited: edited,
  batches: batches
}

File.write!(output, :json.encode(result))
File.rm_rf(base)
IO.inspect(result, limit: :infinity)
