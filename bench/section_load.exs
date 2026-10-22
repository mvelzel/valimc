# What a section's load costs the log in a world with a large one (VMC-077t):
# one stripe holds `OWNERS` owners' frames, `FRAMES` each of 64 KiB, none
# covered by a checkpoint. Then timed, `LOADS` times each:
#
# - `Log.frames/3` of an owner never written (a fresh section);
# - `Log.frames/3` of an owner with frames in the log;
# - `Log.frames/3` of an owner whose frames a checkpoint covers;
# - `RegionStorage.open/2` of a never-written section (checkpoint, log, parts).
#
#   MIX_ENV=bench mix run --no-start bench/section_load.exs <scratch-dir> [results.json]
alias Valimc.Storage.Log

[base | rest] = System.argv()
base = Path.expand(base)
false = File.exists?(base)
File.mkdir_p!(base)
Application.put_env(:valimc, :world_path, base)
Application.put_env(:valimc, :port, 0)
{:ok, _} = Application.ensure_all_started(:valimc)

owners = String.to_integer(System.get_env("OWNERS", "400"))
per_owner = String.to_integer(System.get_env("FRAMES", "10"))
loads = String.to_integer(System.get_env("LOADS", "20"))
route = {:region, :overworld, {500_000, 0}}
payload = :binary.copy(<<7>>, 64 * 1024)
owner = fn n -> {:region, :overworld, {500_000 + n, 0}} end

frame = fn n, seq ->
  :erlang.term_to_binary([{:put, {:block_entity, {n, seq, 0}}, {"bench", payload}}])
end

written = System.monotonic_time(:millisecond)

for seq <- 1..per_owner, chunk <- Enum.chunk_every(0..(owners - 1), 50) do
  frames = for n <- chunk, do: {owner.(n), seq, frame.(n, seq)}
  Log.commit_group(base, route, frames, self())

  for {o, s, _} <- frames do
    receive do
      {:storage_durable, ^o, ^s} -> :ok
    after
      60_000 -> raise "no durable acknowledgement"
    end
  end
end

log_bytes =
  Path.wildcard(Path.join(Log.dir(base, Log.stripe(route)), "log.*"))
  |> Enum.map(&File.stat!(&1).size)
  |> Enum.sum()

written = System.monotonic_time(:millisecond) - written

# The last owners' frames are covered by a (pretend) checkpoint.
for n <- (owners - loads)..(owners - 1), do: Log.covered(base, owner.(n), per_owner)
:sys.get_state(elem(hd(Registry.lookup(Valimc.StorageRegistry, {base, Log.stripe(route)})), 0))

time = fn fun ->
  :erlang.garbage_collect()

  samples =
    for i <- 1..loads do
      started = System.monotonic_time(:microsecond)
      fun.(i)
      System.monotonic_time(:microsecond) - started
    end

  sorted = Enum.sort(samples)

  %{
    p50_us: Enum.at(sorted, div(loads, 2)),
    max_us: List.last(sorted),
    mean_us: div(Enum.sum(sorted), loads)
  }
end

open_fresh =
  time.(fn i -> {:ok, _, _} = Valimc.World.RegionStorage.open(:overworld, {600_000 + i, 0}) end)

result = %{
  open_fresh_section: open_fresh,
  log_bytes: log_bytes,
  owners: owners,
  frames_per_owner: per_owner,
  write_ms: written,
  never_written: time.(fn i -> [] = Log.frames(base, owner.(owners + 1000 + i), 0) end),
  with_frames:
    time.(fn i ->
      frames = Log.frames(base, owner.(i), 0)
      ^per_owner = length(frames)
    end),
  covered: time.(fn i -> [] = Log.frames(base, owner.(owners - i), 0) end)
}

commit = System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()
IO.inspect(result, label: "section load")

case rest do
  [out | _] -> File.write!(out, :json.encode(Map.put(result, :commit, commit)))
  [] -> :ok
end
