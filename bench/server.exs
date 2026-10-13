path = System.fetch_env!("VALIMC_METRICS_FILE")

spawn_link(fn ->
  loop = fn loop ->
    sample = Map.put(Valimc.Metrics.snapshot(), :time_ms, System.monotonic_time(:millisecond))
    File.write!(path, :json.encode(sample))
    Process.sleep(100)
    loop.(loop)
  end

  loop.(loop)
end)

IO.gets("")
System.stop(0)
