alias Valimc.Protocol.ClientTick
[path] = System.argv()
traces = path |> File.read!() |> JSON.decode!()

for c <- traces do
  trace = c["events"]

  Enum.reduce(trace, %ClientTick{}, fn row, state ->
    result =
      case row["event"] do
        kind when kind in ["pos", "pos_rot"] -> ClientTick.position(state)
        "end" -> {:ok, ClientTick.finish(state)}
        kind when kind in ["rot", "status"] -> {:ok, state}
      end

    {rejected, next} =
      case result do
        {:ok, next} -> {false, next}
        {:error, :duplicate_position} -> {true, state}
      end

    if rejected != row["rejected"] or next.position_received? != row["position"],
      do: raise("Native client-tick mismatch: #{inspect(c)} at #{inspect(row)}")

    next
  end)
end

IO.puts("PASS: #{length(traces)} native client-tick handler traces match connection admission.")
