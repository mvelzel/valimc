alias Valimc.Blocks.Mining
alias Valimc.Player.MiningAttempt
alias Valimc.Protocol.{Data, Packets}
[input] = System.argv()
facts = input |> File.read!() |> JSON.decode!()

stage = fn n -> if n in 0..9, do: n, else: -1 end

native_events = fn events ->
  Enum.map(events, fn
    "destroy" -> :ready
    "crack:" <> number -> {:crack, stage.(String.to_integer(number))}
  end)
end

for row <- facts["traces"] do
  {:ok, rate} = Mining.rate(row["state"], row["speed"], row["correct"])
  {:ok, attempt, events} = MiningAttempt.start({0, 0, 0}, row["state"], rate, 0)

  unless events == native_events.(row["start_events"]),
    do: raise("Native mining start differs #{inspect(row)}")

  if attempt.phase != :ready do
    {attempt, events} =
      Enum.reduce(if(row["stop"] == 0, do: [], else: 1..row["stop"]), {attempt, []}, fn tick,
                                                                                        {attempt,
                                                                                         events} ->
        {:ok, attempt, next} = MiningAttempt.tick(attempt, row["state"], rate, tick)
        {attempt, events ++ next}
      end)

    # Native stages outside0..9 all clear the animation; coalesce redundant clears.
    native =
      row["tick_events"]
      |> native_events.()
      |> Enum.dedup()

    unless events == native, do: raise("Native active mining ticks differ #{inspect(row)}")
    {:ok, attempt, events} = MiningAttempt.stop(attempt, row["state"], rate, row["stop"])

    unless events == native_events.(row["stop_events"]) and
             attempt.phase == :finishing == row["delayed"],
           do: raise("Native mining stop differs #{inspect(row)}")
  end
end

unless facts["delayed_limit"] == [
         %{"started" => 0, "destroyed" => false, "delayed" => true},
         %{"started" => 123, "destroyed" => true, "delayed" => false}
       ],
       do:
         raise("Pinned native delayed-tick behavior changed; review intentional elapsed-tick fix")

unless length(facts["traces"]) == 490, do: raise("Missing native mining attempt traces")

for row <- facts["packets"] do
  {id, body} =
    Packets.block_destruction(row["entity"], List.to_tuple(row["position"]), row["stage"])

  unless id == Data.id(:play, :clientbound, "block_destruction") and
           Base.encode16(IO.iodata_to_binary(body), case: :lower) == row["wire"],
         do: raise("Native destruction codec differs #{inspect(row)}")
end

unless length(facts["packets"]) == 165, do: raise("Missing native destruction packets")
IO.puts("PASS: 490 actual native start/tick/stop traces; redundant visual clears coalesced.")

IO.puts(
  "PASS: 165 native destruction packets across IDs, positions and all visible/clear stages."
)

IO.puts(
  "OBSERVED: native delayed progress uses absolute start tick; ValiMC uses elapsed owner ticks."
)
