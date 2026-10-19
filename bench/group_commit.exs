# Group commit (VMC-063): durable throughput and commits per datasync.
#
#   MIX_ENV=prod mix run --no-start bench/group_commit.exs <scratch-dir> [results.json]
#
# Region workload: C concurrent callers each create and remove items in one
# region (two durable writes per cycle); every reply means the frame is durable. Player workload: P processes each save
# a player snapshot repeatedly through `Valimc.PlayerLog`.
alias Valimc.World
alias Valimc.World.Region
alias Valimc.Protocol.ItemStack

[base | rest] = System.argv()
File.mkdir_p!(base)
Application.put_env(:valimc, :port, 0)
Application.put_env(:valimc, :world_path, Path.expand(base))
Application.put_env(:valimc, :item_simulation, false)
{:ok, _} = Application.ensure_all_started(:valimc)
metric = fn key -> Map.get(Valimc.Metrics.snapshot(), key, 0) end

# Only the retryable refusals are retried.
retry = fn op ->
  Stream.repeatedly(op)
  |> Enum.find(
    &(not match?({:error, busy} when busy in [:item_storage_busy, :storage_backpressure], &1))
  )
end

region =
  for {callers, index} <- Enum.with_index([1, 8, 64]) do
    key = {9300 + index, 9300}
    {rx, rz} = key
    {:ok, owner} = World.item_owner(key)
    per = div(512, callers)
    {batches, commits} = {metric.(:store_batches), metric.(:store_batch_commits)}

    {us, _} =
      :timer.tc(fn ->
        1..callers
        |> Task.async_stream(
          fn c ->
            position = {rx * 128 + 0.5 + rem(c, 100), 64.5, rz * 128 + 0.5}

            for _ <- 1..per do
              {:ok, handle} =
                retry.(fn -> Region.create_item(owner, ItemStack.new("stone"), position) end)

              :ok = retry.(fn -> Region.remove_item(handle) end)
            end
          end,
          max_concurrency: callers,
          timeout: :infinity
        )
        |> Stream.run()
      end)

    n = 2 * per * callers
    batches = metric.(:store_batches) - batches
    commits = metric.(:store_batch_commits) - commits

    %{
      workload: "region_creates",
      callers: callers,
      operations: n,
      seconds: us / 1.0e6,
      ops_per_second: round(n / (us / 1.0e6)),
      commits_per_datasync: Float.round(commits / max(batches, 1), 2)
    }
  end

players =
  for players <- [1, 64, 512] do
    dir = Path.join([Path.expand(base), "players"])
    rounds = div(4096, players)
    {batches, commits} = {metric.(:player_log_batches), metric.(:player_log_commits)}
    bytes = :crypto.strong_rand_bytes(2048)

    {us, _} =
      :timer.tc(fn ->
        1..players
        |> Task.async_stream(
          fn p ->
            path = Path.join(dir, "bench-#{players}-#{p}.pose")
            for _ <- 1..rounds, do: :ok = Valimc.PlayerLog.commit(path, bytes)
          end,
          max_concurrency: players,
          timeout: :infinity
        )
        |> Stream.run()
      end)

    n = rounds * players
    batches = metric.(:player_log_batches) - batches
    commits = metric.(:player_log_commits) - commits

    %{
      workload: "player_saves",
      players: players,
      operations: n,
      seconds: us / 1.0e6,
      ops_per_second: round(n / (us / 1.0e6)),
      commits_per_datasync: Float.round(commits / max(batches, 1), 2)
    }
  end

results = %{
  revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  os: :os.type() |> Tuple.to_list() |> Enum.join("/"),
  schedulers: System.schedulers_online(),
  full_fsync: Application.get_env(:valimc, :full_fsync),
  results: region ++ players
}

for r <- results.results, do: IO.inspect(r)

case rest do
  [out] -> File.write!(out, :json.encode(results))
  [] -> :ok
end
