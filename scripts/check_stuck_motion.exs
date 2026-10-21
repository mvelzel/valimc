alias Valimc.Physics.StuckMotion
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end
vector = fn tuple -> Enum.map(Tuple.to_list(tuple), bits) end

for c <- cases["contacts"] do
  kind =
    %{
      "none" => :none,
      "cobweb" => :cobweb,
      "berry_bush" => :berry_bush,
      "powder_snow" => :powder_snow
    }[c["kind"]]

  {:ok, contact} = StuckMotion.player_contact(kind, c["weaving"], c["powder_feet"], c["flying"])
  actual = if contact.multiplier, do: vector.(contact.multiplier)
  expected = if c["multiplier"], do: Enum.map(c["multiplier"], bits)

  unless actual == expected and if(contact.reset_fall, do: 0.0, else: 5.0) == c["fall_distance"],
    do: raise("Native slowing contact mismatch #{inspect(c)} #{inspect(contact)}")
end

for c <- cases["moves"] do
  {:ok, actual} =
    StuckMotion.prepare(
      List.to_tuple(c["requested"]),
      List.to_tuple(c["initial"]),
      List.to_tuple(c["multiplier"])
    )

  for {key, expected} <- [requested: "scaled", velocity: "velocity", multiplier: "remaining"] do
    unless vector.(actual[key]) == Enum.map(c[expected], bits),
      do: raise("Native stuck move mismatch #{key} #{inspect(c)} #{inspect(actual)}")
  end
end

IO.puts(
  "PASS: #{length(cases["contacts"])} native slowing contacts and #{length(cases["moves"])} actual move prefixes."
)
