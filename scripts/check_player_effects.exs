alias Valimc.{PlayerEffects, StatusEffect}
[path] = System.argv()
facts = :json.decode(File.read!(path))

unless facts["version"] == "26.3" and facts["data_version"] == 5023 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
         length(facts["traces"]) == 129,
       do: raise("Wrong native effect map reference")

for trace <- facts["traces"] do
  Enum.reduce(trace, %{}, fn row, previous ->
    id = row["id"]

    {next, changed, events} =
      case row["op"] do
        "add" ->
          flags = row["flags"]

          {:ok, incoming} =
            StatusEffect.new(
              row["ticks"],
              row["amplifier"],
              Bitwise.band(flags, 1) != 0,
              Bitwise.band(flags, 2) != 0,
              Bitwise.band(flags, 4) != 0
            )

          {:ok, next, changed} = PlayerEffects.add(previous, id, incoming)
          kind = if Map.has_key?(previous, id), do: "update", else: "add"
          events = if changed, do: [[kind, id, kind == "update"]], else: []
          {next, changed, events}

        "remove" ->
          {:ok, next, changed} = PlayerEffects.remove(previous, id)
          {next, changed, if(changed, do: [["remove", id, false]], else: [])}

        "tick" ->
          {:ok, next, events} = PlayerEffects.tick(previous)

          {next, nil,
           Enum.map(events, fn {kind, id, reset} -> [Atom.to_string(kind), id, reset] end)}
      end

    expected =
      Map.new(row["state"], fn entry ->
        {entry["id"], Enum.map(entry["rungs"], &List.to_tuple/1)}
      end)

    # Cross-effect callback order is not an authority boundary; retain order within each effect.
    native_events = Enum.group_by(row["events"], &Enum.at(&1, 1))
    events = Enum.group_by(events, &Enum.at(&1, 1))

    unless next == expected and changed == row["changed"] and events == native_events,
      do:
        raise(
          "Native effect map differs: #{inspect(row)} actual #{inspect({next, changed, events})}"
        )

    next
  end)
end

IO.puts(
  "PASS: 129 native LivingEntity effect-map traces, including exact add/update/remove and promotion/600-tick notifications. Actions/attributes/live ownership excluded."
)
