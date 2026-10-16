alias Valimc.{PlayerAbsorption, PlayerEffects}
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
    PlayerAbsorption.derive(%{id => [{200, row["amplifier"], false, true, true}]}, row["base"])

  {22, base, modifiers} = derived.attribute
  assert.(base == row["base"] and Enum.map(modifiers, &Tuple.to_list/1) == row["modifiers"], row)
  assert.(derived.maximum == row["set"]["maximum"], row)
  {:ok, pool} = PlayerAbsorption.set(row["requested"], derived.maximum)
  assert.(pool == row["set"]["pool"], row)
  {:ok, started} = PlayerAbsorption.start(pool, derived.maximum, row["amplifier"])
  assert.(started == row["started"]["pool"], row)
  {:ok, removed} = PlayerAbsorption.derive(%{}, row["base"])
  {:ok, pool} = PlayerAbsorption.set(started, removed.maximum)
  assert.(pool == row["removed"]["pool"] and removed.maximum == row["removed"]["maximum"], row)
end

for row <- data["additions"] do
  {:ok, effects, changed} =
    PlayerEffects.add(state.(row["before"]), id, [
      {row["incoming_ticks"], row["incoming_amplifier"], false, true, true}
    ])

  {:ok, derived} = PlayerAbsorption.derive(effects)
  {:ok, clamped} = PlayerAbsorption.set(row["before"]["pool"], derived.maximum)
  {:ok, pool} = PlayerAbsorption.start(clamped, derived.maximum, row["incoming_amplifier"])

  assert.(
    changed == row["changed"] and effects[id] == rungs.(row["after"]["rungs"]) and
      pool == row["after"]["pool"] and derived.maximum == row["after"]["maximum"],
    row
  )
end

for row <- data["ticks"] do
  {:ok, next, remains, promoted} =
    PlayerAbsorption.tick(rungs.(row["before"]["rungs"]), row["before"]["pool"])

  assert.(
    remains == row["remains"] and elem(hd(next), 0) == row["next_ticks"] and
      promoted == row["promotions"] > 0,
    row
  )
end

for row <- data["promotions"] do
  {:ok, next, remains, promoted} =
    PlayerAbsorption.tick(rungs.(row["before"]["rungs"]), row["before"]["pool"])

  {:ok, derived} = PlayerAbsorption.derive(%{id => next})
  {:ok, pool} = PlayerAbsorption.set(row["before"]["pool"], derived.maximum)

  assert.(
    remains == row["remains"] and promoted == remains and next == rungs.(row["after"]["rungs"]) and
      pool == row["after"]["pool"] and derived.maximum == row["after"]["maximum"],
    row
  )
end

for row <- data["removals"] do
  {:ok, derived} = PlayerAbsorption.derive(%{}, row["base"])
  {:ok, pool} = PlayerAbsorption.set(row["before"]["pool"], derived.maximum)

  assert.(
    row["removed"] and row["after"]["rungs"] == [] and pool == row["after"]["pool"] and
      derived.maximum == row["after"]["maximum"],
    row
  )
end

IO.puts(
  "PASS: #{length(data["setters"])} native Absorption setter/start/removal contexts, #{length(data["additions"])} refreshes, #{length(data["ticks"])} instance ticks, #{length(data["promotions"])} promotions and #{length(data["removals"])} actual removals; live damage/owner excluded."
)
