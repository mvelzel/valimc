alias Valimc.AI.{Facts, Mind, Self, World}
alias Valimc.Entity.Body
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) >= 500, do: raise("Incomplete pufferfish resize fixtures")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

air = Valimc.Data.Blocks.default_state("air")

for row <- cases do
  {:ok, body} = Body.new("minecraft:pufferfish")
  body = %{body | data: %{body.data | puff: row["old"]}}
  {width, height, eye} = Body.dimensions(body)
  [x, y, z] = Enum.map(row["before"], double)
  cells = Map.new(row["cells"], fn [x, y, z, state] -> {{x, y, z}, state} end)

  self =
    Valimc.AI.Mobs.Pufferfish.tick_start(%Self{
      type: body.type,
      uuid: <<1::128>>,
      x: x,
      y: y,
      z: z,
      width: width,
      height: height,
      eye: eye,
      data: body.data,
      mob: body.mob,
      facts: Facts.mob(body.type),
      mind: %Mind{
        random: Valimc.AI.Random.new(7),
        own: %{inflate: if(row["old"] == 0, do: 1, else: 41), deflate: 0}
      },
      world: %World{
        read: &Map.get(cells, &1, air),
        border: row["border"] && List.to_tuple(row["border"])
      }
    })

  expected = Enum.map(row["after"], double)
  actual = [self.x, self.y, self.z]

  if actual != expected,
    do:
      raise(
        "#{row["scene"]} puff #{row["old"]}: #{inspect([x, y, z])} -> #{inspect(actual)}; native #{inspect(expected)}"
      )

  bits = fn v ->
    <<n::signed-32>> = <<v::float-32>>
    n
  end

  true = Enum.map([self.width, self.height, self.eye], bits) == row["dimensions"]
end

IO.puts("PASS: #{length(cases)} native pufferfish collision-resize positions and dimensions")
