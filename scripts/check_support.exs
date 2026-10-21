# Differential check of live play's survival facts (VMC-029c) against SupportOracle's
# random neighbourhoods: vanilla canSurvive and updateShape against the block rules
# (VMC-077m, `valimc_core::rules::support`).
[filename] = System.argv()
cases = JSON.decode!(File.read!(filename))
rules = Valimc.Block.Rules.native()

updates =
  for [state, direction, _alive, _vanilla, cells] <- cases["updates"],
      do: {state, direction, for([dx, dy, dz, block] <- cells, do: {dx, dy, dz, block})}

states = for [state, _] <- cases["remains"], do: state
{:ok, {results, dependent}} = Valimc.Native.rules_support_cases(rules, updates, states)

mismatches =
  for {[_, _, alive, vanilla, _] = row, {ours_alive, ours}} <- Enum.zip(cases["updates"], results),
      ours_alive != alive or ours != vanilla,
      do: row

unless mismatches == [] do
  IO.puts("#{length(mismatches)} mismatches, first: #{inspect(Enum.take(mismatches, 5))}")
  System.halt(1)
end

for {[state, remains], true} <- Enum.zip(cases["remains"], dependent),
    Valimc.Block.after_removal(state) != remains,
    do: raise("support remains mismatch: #{state}")

unless Enum.all?(dependent), do: raise("a state with remains has no survival facts")

IO.puts(
  "PASS: #{length(cases["updates"])} vanilla survival/update neighbourhoods and the remains of " <>
    "#{length(cases["remains"])} dependent states match the block rules."
)
