alias Valimc.Data.EffectTypes
alias Valimc.Living.Attributes
alias Valimc.Protocol.ItemStack
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 720, do: raise("Incomplete attack-speed fixtures")

for row <- rows do
  hand = if row["mainhand"] and row["item"] != "minecraft:air", do: ItemStack.new(row["item"])

  effects =
    for {name, level} <- [{"haste", row["haste"]}, {"mining_fatigue", row["fatigue"]}],
        level >= 0,
        into: %{},
        do: {EffectTypes.id(name), [{200, level, false, true, true}]}

  {:ok, derived} = Attributes.attack_speed(hand, effects)
  {id, base, modifiers} = derived.attribute
  modifiers = Enum.map(modifiers, &Tuple.to_list/1) |> Enum.sort()
  expected = Enum.sort(row["modifiers"])

  unless {id, base, modifiers} == {row["id"], row["base"], expected},
    do: raise("Attack-speed modifiers #{inspect(row)}: #{inspect(derived)}")

  bits = Base.encode16(<<derived.value::float-64>>, case: :lower)

  unless bits == row["value"],
    do: raise("Attack-speed value #{inspect(row)}: #{bits} != #{row["value"]}")

  delay =
    case Valimc.Living.Melee.strength_delay(derived.value) do
      :infinity ->
        0x7F800000

      value ->
        <<bits::32>> = <<value::float-32>>
        bits
    end

  unless delay == row["delay"], do: raise("Native attack delay differs")

  for [tick, partial, expected, weak] <- row["strengths"] do
    strength = Valimc.Living.Melee.strength(tick, derived.value, partial)
    <<bits::32>> = <<strength::float-32>>
    unless bits == expected, do: raise("Native strength differs: #{inspect(row)}")

    unless Valimc.Living.Melee.too_weak?(0.25, tick, derived.value, 2) == weak,
      do: raise("Native minimum-charge admission differs")
  end
end

IO.puts(
  "PASS: 720 native attack-speed attributes and exact values, 7200 strength samples and minimum-charge decisions, including zero speed"
)
