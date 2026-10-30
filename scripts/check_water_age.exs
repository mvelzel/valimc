alias Valimc.Entity.{Body, MobFacts, Store}
alias Valimc.Native
alias Valimc.Protocol.ItemStack

[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 48, do: raise("Incomplete water-age fixtures")
MobFacts.install!()

# The player a dolphin's family is asked whether it bites.
player = %{uuid: <<2::128>>, mode: :survival, position: {4.0, 64.0, 0.0}}

for row <- cases do
  {:ok, body} = Body.new(row["type"])

  body = %{
    body
    | data: %{body.data | age: row["age"], age_locked: row["locked"]},
      mob: %{body.mob | no_ai: true}
  }

  section = Native.mob_section_oracle_new()

  {:ok, _} =
    Native.mob_section_insert(
      section,
      [{1, Store.body_record(body, <<1::128>>, {0.0, 64.0, 0.0})}],
      false
    )

  # Its mind's random seeded with 7; the voice draws from a copy of it.
  {_, _, _, _, _, pitch} = Native.mob_oracle_body_turn(section, 1, :voice, %{random: 7})
  <<pitch_bits::signed-32>> = <<pitch::float-32>>
  true = pitch_bits == row["voice_pitch"]

  if row["feed"] do
    {:ok, {outcome, _, _}} =
      Native.mob_section_interact(section, 1, ItemStack.new("cod", 3), nil, false, [])

    {:use, 1} = elem(outcome, 1)
    2 = row["remaining"]
  end

  bits = fn v ->
    <<n::signed-32>> = <<v::float-32>>
    n
  end

  for {expected, tick} <- Enum.with_index(row["trace"]) do
    {_, native, _, _, timer, bites} =
      Native.mob_oracle_body_turn(section, 1, :can_attack, %{players: [player]})

    {width, height, eye} = native.dimensions

    actual = %{
      age: native.data.age,
      forced_age: native.data.forced_age,
      age_locked: native.data.age_locked,
      timer: timer,
      dimensions: Enum.map([width, height, eye], bits),
      got_fish: native.data[:got_fish],
      can_attack: native.type == "minecraft:dolphin" and bites
    }

    for name <- ~w(age forced_age age_locked timer dimensions got_fish can_attack),
        Map.has_key?(expected, name) do
      if actual[String.to_existing_atom(name)] != expected[name],
        do:
          raise(
            "#{row["type"]} #{inspect(row |> Map.delete("trace"))} tick #{tick}: #{inspect(actual)} != #{inspect(expected)}"
          )
    end

    # `AgeableMob.aiStep`.
    Native.mob_oracle_body_turn(section, 1, :settle_ageable, %{})
  end
end

IO.puts(
  "PASS: 48 native ageable ocean-mob growth, lock, feeding and dimension traces (42 steps each)"
)
