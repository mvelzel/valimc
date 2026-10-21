alias Valimc.Living.{Attributes, Effects, Health}
alias Valimc.Protocol.EffectTypes
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
id = EffectTypes.id("absorption")
rungs = fn rows -> Enum.map(rows, fn [ticks, amp] -> {ticks, amp, false, true, true} end) end
state = fn row -> %{id => rungs.(row["rungs"])} end

assert = fn matches, row ->
  if not matches, do: raise("Native Absorption differs: #{inspect(row)}")
end

for row <- data["setters"] do
  {:ok, derived} =
    Attributes.absorption(%{id => [{200, row["amplifier"], false, true, true}]}, row["base"])

  {22, base, modifiers} = derived.attribute
  assert.(base == row["base"] and Enum.map(modifiers, &Tuple.to_list/1) == row["modifiers"], row)
  assert.(derived.maximum == row["set"]["maximum"], row)
  {:ok, pool} = Health.set_absorption(row["requested"], derived.maximum)
  assert.(pool == row["set"]["pool"], row)
  {:ok, started} = Health.start_absorption(pool, derived.maximum, row["amplifier"])
  assert.(started == row["started"]["pool"], row)
  {:ok, removed} = Attributes.absorption(%{}, row["base"])
  {:ok, pool} = Health.set_absorption(started, removed.maximum)
  assert.(pool == row["removed"]["pool"] and removed.maximum == row["removed"]["maximum"], row)
end

for row <- data["additions"] do
  {:ok, effects, changed} =
    Effects.add(state.(row["before"]), id, [
      {row["incoming_ticks"], row["incoming_amplifier"], false, true, true}
    ])

  {:ok, derived} = Attributes.absorption(effects)
  {:ok, clamped} = Health.set_absorption(row["before"]["pool"], derived.maximum)
  {:ok, pool} = Health.start_absorption(clamped, derived.maximum, row["incoming_amplifier"])

  assert.(
    changed == row["changed"] and effects[id] == rungs.(row["after"]["rungs"]) and
      pool == row["after"]["pool"] and derived.maximum == row["after"]["maximum"],
    row
  )
end

for row <- data["ticks"] do
  {:ok, next, remains, promoted} =
    Health.tick_absorption(rungs.(row["before"]["rungs"]), row["before"]["pool"])

  assert.(
    remains == row["remains"] and elem(hd(next), 0) == row["next_ticks"] and
      promoted == row["promotions"] > 0,
    row
  )
end

for row <- data["promotions"] do
  {:ok, next, remains, promoted} =
    Health.tick_absorption(rungs.(row["before"]["rungs"]), row["before"]["pool"])

  {:ok, derived} = Attributes.absorption(%{id => next})
  {:ok, pool} = Health.set_absorption(row["before"]["pool"], derived.maximum)

  assert.(
    remains == row["remains"] and promoted == remains and next == rungs.(row["after"]["rungs"]) and
      pool == row["after"]["pool"] and derived.maximum == row["after"]["maximum"],
    row
  )
end

for row <- data["removals"] do
  {:ok, derived} = Attributes.absorption(%{}, row["base"])
  {:ok, pool} = Health.set_absorption(row["before"]["pool"], derived.maximum)

  assert.(
    row["removed"] and row["after"]["rungs"] == [] and pool == row["after"]["pool"] and
      derived.maximum == row["after"]["maximum"],
    row
  )
end

IO.puts(
  "PASS: #{length(data["setters"])} native Absorption setter/start/removal contexts, #{length(data["additions"])} refreshes, #{length(data["ticks"])} instance ticks, #{length(data["promotions"])} promotions and #{length(data["removals"])} actual removals; live damage/owner excluded."
)
