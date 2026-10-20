# Differential check of the generated survival facts (VMC-029c) against SupportOracle's
# random neighbourhoods: vanilla canSurvive and updateShape against Valimc.Block.Support.
[filename] = System.argv()
cases = JSON.decode!(File.read!(filename))
alias Valimc.Block.Support
origin = {0, 64, 0}
air = Valimc.Registry.Blocks.default_state("air")

outcome = fn
  -1 -> :break
  0 -> :keep
  delay -> {:tick, delay}
end

mismatches =
  for [state, direction, alive, vanilla, cells] = row <- cases["updates"],
      cells = Map.new(cells, fn [dx, dy, dz, block] -> {{dx, 64 + dy, dz}, block} end),
      read = fn
        ^origin -> state
        position -> Map.get(cells, position, air)
      end,
      Support.survives?(origin, state, read) != alive or
        Support.update(origin, state, [direction], read) != outcome.(vanilla),
      do: row

unless mismatches == [] do
  IO.puts("#{length(mismatches)} mismatches, first: #{inspect(Enum.take(mismatches, 5))}")
  System.halt(1)
end

for [state, remains] <- cases["remains"] do
  unless Support.dependent?(state) and Valimc.Block.after_removal(state) == remains,
    do: raise("support remains mismatch: #{state}")
end

IO.puts(
  "PASS: #{length(cases["updates"])} vanilla survival/update neighbourhoods and the remains of " <>
    "#{length(cases["remains"])} dependent states match the generated support facts."
)
