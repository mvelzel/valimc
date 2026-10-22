alias Valimc.Native
alias Valimc.Player.{GameMode, Food}
import Bitwise
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
cases = data["movement"]

for c <- cases do
  flags = c["flags"]

  contact = %{
    passenger: (flags &&& 1) != 0,
    swimming: (flags &&& 2) != 0,
    underwater: (flags &&& 4) != 0,
    water: (flags &&& 8) != 0,
    climbing: (flags &&& 16) != 0,
    grounded: (flags &&& 32) != 0,
    sprinting: (flags &&& 64) != 0
  }

  movement = c["movement"] |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()
  {:ok, amount} = Native.physics_player_parity(:food_travel, {movement, contact})

  unless amount == c["exhaustion"],
    do: raise("Native movement food mismatch #{inspect({c, amount})}")
end

for c <- data["gates"] do
  mode = GameMode.new(String.to_existing_atom(c["mode"]))

  food =
    if GameMode.abilities(mode, false).invulnerable,
      do: %Food{},
      else: Food.exhaust(%Food{}, c["amount"])

  unless food.exhaustion == c["exhaustion"],
    do: raise("Native exhaustion ability gate differs #{inspect(c)}")
end

for c <- data["jumps"],
    do:
      unless(Native.physics_player_parity(:food_jump, c["sprinting"]) == {:ok, c["exhaustion"]},
        do: raise("Native jump exhaustion differs #{inspect(c)}")
      )

IO.puts(
  "PASS: #{length(cases)} native travel requests, #{length(data["gates"])} Player ability gates and #{length(data["jumps"])} ServerPlayer jump callbacks; owner composition remains separate."
)
