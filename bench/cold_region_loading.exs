alias Valimc.World
alias Valimc.World.Region
[output] = System.argv()
base = Path.join(System.tmp_dir!(), "valimc-cold-bench-#{System.unique_integer([:positive])}")
File.mkdir_p!(base)
old = Valimc.config(:world_path)
Application.put_env(:valimc, :world_path, base)
{:ok, hot} = World.owner({709, 710})
bytes = :erlang.term_to_binary({:valimc_region, 1, %{}})

registered = fn key ->
  Enum.reduce_while(1..1000, nil, fn _, _ ->
    case Registry.lookup(Valimc.RegionRegistry, key) do
      [{pid, _}] ->
        {:halt, pid}

      [] ->
        Process.sleep(1)
        {:cont, nil}
    end
  end) || raise "Cold owner not registered"
end

now = fn -> System.monotonic_time(:microsecond) end

measure = fn work ->
  started = now.()
  result = work.()
  {result, now.() - started}
end

results =
  for n <- 0..4 do
    cold_key = {710 + n * 2, 710}
    other_key = {711 + n * 2, 710}
    path = Path.join(base, "r.#{elem(cold_key, 0)}.710.etf")
    {_, 0} = System.cmd("mkfifo", [path])
    cold = Task.async(fn -> measure.(fn -> World.owner(cold_key) end) end)
    pid = registered.(cold_key)
    nil = Task.yield(cold, 10)
    unpublished = World.existing_owner(cold_key) == {:error, :region_unavailable}

    release =
      Task.async(fn ->
        Process.sleep(200)
        :ok = File.write(path, bytes, [:raw])
      end)

    other = Task.async(fn -> measure.(fn -> World.owner(other_key) end) end)
    {{:ok, _}, hot_us} = measure.(fn -> Region.observe_blocks(hot, []) end)
    {{:ok, {other_pid, _}}, independent_us} = Task.await(other, 4000)
    {{:ok, {^pid, _}}, cold_us} = Task.await(cold, 4000)
    :ok = Task.await(release, 1000)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, other_pid)

    %{
      cold_region: Tuple.to_list(cold_key),
      independent_region: Tuple.to_list(other_key),
      cold_load_us: cold_us,
      independent_load_us: independent_us,
      existing_owner_read_us: hot_us,
      incomplete_owner_unpublished: unpublished,
      injected_stall_ms: 200
    }
  end

:ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(hot, 0))
Application.put_env(:valimc, :world_path, old)
File.rm_rf!(base)

record = %{
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  schedulers: System.schedulers_online(),
  scope:
    "Five local cold loads with an actual FIFO open/read stalled for 200 ms, plus an unrelated new owner and an existing owner read; no network or cross-server capacity claim.",
  persisted_bytes_hex: Base.encode16(bytes, case: :lower),
  source_sha256: :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower),
  implementation_sha256:
    Map.new(Path.wildcard("lib/**/*.ex"), fn path ->
      {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
    end),
  results: results
}

File.write!(output, JSON.encode!(record))
IO.inspect(results)
