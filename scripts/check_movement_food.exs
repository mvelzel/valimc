alias Valimc.Physics.MovementFood
alias Valimc.{GameMode, PlayerFood}
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

  amount = MovementFood.amount(List.to_tuple(c["movement"]), contact)

  unless amount == c["exhaustion"],
    do: raise("Native movement food mismatch #{inspect({c, amount})}")
end

for c <- data["gates"] do
  mode = GameMode.new(String.to_existing_atom(c["mode"]))

  food =
    if GameMode.abilities(mode, false).invulnerable,
      do: %PlayerFood{},
      else: PlayerFood.exhaust(%PlayerFood{}, c["amount"])

  unless food.exhaustion == c["exhaustion"],
    do: raise("Native exhaustion ability gate differs #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(cases)} native movement exhaustion requests and #{length(data["gates"])} actual Player ability gates; owner composition remains separate."
)
