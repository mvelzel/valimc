alias Valimc.Native
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end
vector = fn tuple -> Enum.map(Tuple.to_list(tuple), bits) end
vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

for c <- cases["contacts"] do
  kind =
    %{
      "none" => :none,
      "cobweb" => :cobweb,
      "berry_bush" => :berry_bush,
      "powder_snow" => :powder_snow
    }[c["kind"]]

  {:ok, multiplier} =
    Native.physics_player_parity(
      :player_contact,
      {kind, c["weaving"], c["powder_feet"], c["flying"]}
    )

  actual = if multiplier, do: vector.(multiplier)
  expected = if c["multiplier"], do: Enum.map(c["multiplier"], bits)

  unless actual == expected and if(multiplier, do: 0.0, else: 5.0) == c["fall_distance"],
    do: raise("Native slowing contact mismatch #{inspect(c)} #{inspect(multiplier)}")
end

for c <- cases["moves"] do
  {:ok, {requested, velocity, multiplier}} =
    Native.physics_player_parity(
      :stuck_prepare,
      {vec.(c["requested"]), vec.(c["initial"]), vec.(c["multiplier"])}
    )

  actual = %{requested: requested, velocity: velocity, multiplier: multiplier}

  for {key, expected} <- [requested: "scaled", velocity: "velocity", multiplier: "remaining"] do
    unless vector.(actual[key]) == Enum.map(c[expected], bits),
      do: raise("Native stuck move mismatch #{key} #{inspect(c)} #{inspect(actual)}")
  end
end

IO.puts(
  "PASS: #{length(cases["contacts"])} native slowing contacts and #{length(cases["moves"])} actual move prefixes."
)
