alias Valimc.Entity.{Body, MobFacts, Store}
alias Valimc.Native
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) >= 500, do: raise("Incomplete pufferfish resize fixtures")
MobFacts.install!()

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

air = Valimc.Data.Blocks.default_state("air")

for row <- cases do
  {:ok, body} = Body.new("minecraft:pufferfish")
  body = %{body | data: %{body.data | puff: row["old"]}}
  [x, y, z] = Enum.map(row["before"], double)
  section = Native.mob_section_oracle_new()

  {:ok, _} =
    Native.mob_section_insert(
      section,
      [{1, Store.body_record(body, <<1::128>>, {x, y, z})}],
      false
    )

  # `Pufferfish.tick` before its super, inflating from its old puff.
  {{ax, ay, az}, _row, {width, height, eye}, _, _, _} =
    Native.mob_oracle_body_turn(section, 1, :tick_start, %{
      cells: row["cells"],
      air: air,
      border: row["border"] && List.to_tuple(row["border"]),
      random: 7,
      inflate: if(row["old"] == 0, do: 1, else: 41)
    })

  expected = Enum.map(row["after"], double)
  actual = [ax, ay, az]

  if actual != expected,
    do:
      raise(
        "#{row["scene"]} puff #{row["old"]}: #{inspect([x, y, z])} -> #{inspect(actual)}; native #{inspect(expected)}"
      )

  bits = fn v ->
    <<n::signed-32>> = <<v::float-32>>
    n
  end

  true = Enum.map([width, height, eye], bits) == row["dimensions"]
end

IO.puts("PASS: #{length(cases)} native pufferfish collision-resize positions and dimensions")
