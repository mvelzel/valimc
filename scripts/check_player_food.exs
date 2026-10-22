alias Valimc.Living.Health
alias Valimc.Player.Food
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
unless data["default_regeneration"], do: raise("Native regeneration default changed")

food = fn row ->
  %Food{
    level: row["level"],
    saturation: row["saturation"],
    exhaustion: row["exhaustion"],
    timer: row["timer"]
  }
end

check = fn actual, expected ->
  unless actual == food.(expected) and Food.valid?(actual),
    do: raise("Native food mismatch #{inspect({actual, expected})}")
end

check.(%Food{}, data["missing"])

unless data["defaults"] == %{
         "foodLevel" => 20,
         "foodSaturationLevel" => 5.0,
         "foodExhaustionLevel" => 0.0,
         "foodTickTimer" => 0
       },
       do: raise("Native food defaults changed")

for c <- data["ticks"] do
  {next, effects} =
    Food.tick(
      food.(c),
      %Health{value: c["health"]},
      c["difficulty"],
      c["regeneration"]
    )

  check.(next, c["next"])

  for phase <- [0, 1, 9, 10, 19],
      Food.idle?(food.(c), %Health{value: c["health"]}, phase) do
    unless next == food.(c) and effects == %{heal: 0.0, damage: 0.0},
      do: raise("Idle food skipped a native transition #{inspect(c)}")
  end

  unless effects == %{heal: c["heal"], damage: c["damage"]},
    do: raise("Native food effects differ #{inspect({c, effects})}")
end

for c <- data["peaceful"] do
  {next, heal} =
    Food.peaceful(
      food.(c),
      %Health{value: c["health"]},
      c["difficulty"],
      c["regeneration"],
      c["tick"]
    )

  check.(next, c["next"])

  if Food.idle?(food.(c), %Health{value: c["health"]}, rem(c["tick"], 20)) do
    unless next == food.(c) and heal == 0.0,
      do: raise("Idle food skipped peaceful recovery #{inspect(c)}")
  end

  unless heal == c["heal"], do: raise("Native peaceful heal differs #{inspect(c)}")
end

for c <- data["exhaustion"],
    do: check.(Food.exhaust(%Food{exhaustion: c["initial"]}, c["amount"]), c["next"])

for c <- data["meals"],
    do: check.(Food.eat(food.(c), c["nutrition"], c["increase"]), c["next"])

IO.puts(
  "PASS: #{length(data["ticks"])} native food ticks, #{length(data["peaceful"])} peaceful prefixes, #{length(data["exhaustion"])} exhaustion and #{length(data["meals"])} meal transitions plus defaults."
)
