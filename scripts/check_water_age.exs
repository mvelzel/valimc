alias Valimc.AI.{Mind, Self, World}
alias Valimc.Entity.{Animal, Body}
alias Valimc.Protocol.ItemStack

[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 48, do: raise("Incomplete water-age fixtures")

for row <- cases do
  {:ok, body} = Body.new(row["type"])

  body = %{
    body
    | data: %{body.data | age: row["age"], age_locked: row["locked"]},
      mob: %{body.mob | no_ai: true, ai: %Mind{random: Valimc.AI.Random.new(7)}}
  }

  {pitch, _} =
    Valimc.AI.Random.voice_pitch(
      Valimc.AI.Random.new(7),
      Valimc.AI.Mobs.voice(body.type, body.data)
    )

  <<pitch_bits::signed-32>> = <<pitch::float-32>>
  true = pitch_bits == row["voice_pitch"]

  body =
    if row["feed"] do
      {:ok, body, %{hand: {:use, 1}}} =
        Valimc.AI.Mobs.Dolphin.mob_interact(body, %{item: ItemStack.new("cod", 3)})

      2 = row["remaining"]
      body
    else
      body
    end

  Enum.reduce(Enum.with_index(row["trace"]), body, fn {expected, tick}, body ->
    {width, height, eye} = Body.dimensions(body)

    bits = fn v ->
      <<n::signed-32>> = <<v::float-32>>
      n
    end

    actual = %{
      age: body.data.age,
      forced_age: body.data.forced_age,
      age_locked: body.data.age_locked,
      timer: body.mob.ai.forced_age_timer,
      dimensions: Enum.map([width, height, eye], bits),
      got_fish: body.data[:got_fish],
      can_attack:
        body.type == "minecraft:dolphin" and
          Valimc.AI.Mobs.Dolphin.can_attack?(%Self{data: body.data}, %{})
    }

    for name <- ~w(age forced_age age_locked timer dimensions got_fish can_attack),
        Map.has_key?(expected, name) do
      if actual[String.to_existing_atom(name)] != expected[name],
        do:
          raise(
            "#{row["type"]} #{inspect(row |> Map.delete("trace"))} tick #{tick}: #{inspect(actual)} != #{inspect(expected)}"
          )
    end

    self =
      Animal.settle_ageable(%Self{
        type: body.type,
        data: body.data,
        mob: body.mob,
        mind: body.mob.ai,
        world: %World{}
      })

    %{body | data: self.data, mob: %{self.mob | ai: self.mind}}
  end)
end

IO.puts(
  "PASS: 48 native ageable ocean-mob growth, lock, feeding and dimension traces (42 steps each)"
)
