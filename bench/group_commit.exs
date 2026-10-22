# Group commit (VMC-063, VMC-077f): durable throughput and records per datasync
# on the world's shared write-ahead log (`Valimc.Storage.Log`).
#
#   MIX_ENV=prod mix run --no-start bench/group_commit.exs <scratch-dir> [results.json]
#
# Region workload: R owners each edit a block every 5 ms for two seconds; each
# replies at once and cuts one frame per 50 ms, and the frames of owners on one
# stripe share its datasyncs. The interval ends with a flush of every owner.
# Players' changes ride in their groups' frames (VMC-077i3), so they have no
# workload of their own.
alias Valimc.World
alias Valimc.World.Region

[base | rest] = System.argv()
File.mkdir_p!(base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, Path.expand(base))
Application.put_env(:valimc, :item_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)
metric = fn key -> Map.get(Valimc.Data.Metrics.snapshot(), key, 0) end

region =
  for owners <- [1, 8, 64] do
    handles =
      for i <- 1..owners do
        key = {9300 + owners * 100 + i, 9300}
        {:ok, owner} = World.owner(Valimc.Data.Grid.section(:overworld, key, :section))
        {key, owner}
      end

    {batches, frames} = {metric.(:storage_batches), metric.(:storage_records)}

    {us, edits} =
      :timer.tc(fn ->
        total =
          handles
          |> Task.async_stream(
            fn {{rx, rz}, owner} ->
              deadline = System.monotonic_time(:millisecond) + 2000

              Stream.iterate(0, &(&1 + 1))
              |> Enum.reduce_while(0, fn i, edits ->
                if System.monotonic_time(:millisecond) >= deadline do
                  {:halt, edits}
                else
                  position = {rx * 128 + rem(i, 16), 64, rz * 128}
                  {:ok, view} = Region.observe_blocks(owner, [position])
                  {:ok, _} = Region.set_blocks(owner, view.revision, %{position => rem(i, 2)})
                  Process.sleep(5)
                  {:cont, edits + 1}
                end
              end)
            end,
            max_concurrency: owners,
            timeout: :infinity
          )
          |> Enum.reduce(0, fn {:ok, n}, acc -> acc + n end)

        for {_, {pid, _}} <- handles, do: :ok = Region.flush(pid)
        total
      end)

    batches = metric.(:storage_batches) - batches
    frames = metric.(:storage_records) - frames

    %{
      workload: "region_frames",
      owners: owners,
      operations: edits,
      seconds: us / 1.0e6,
      frames: frames,
      datasyncs: batches,
      commits_per_datasync: Float.round(frames / max(batches, 1), 2)
    }
  end

results = %{
  revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  os: :os.type() |> Tuple.to_list() |> Enum.join("/"),
  schedulers: System.schedulers_online(),
  full_fsync: Application.get_env(:valimc, :full_fsync),
  results: region
}

for r <- results.results, do: IO.inspect(r)

case rest do
  [out] -> File.write!(out, :json.encode(results))
  [] -> :ok
end
