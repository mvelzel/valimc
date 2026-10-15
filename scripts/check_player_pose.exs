alias Valimc.Physics.PlayerPose
import Bitwise
[path] = System.argv()
native = path |> File.read!() |> JSON.decode!()

for c <- native["poses"] do
  {:ok, dims} = PlayerPose.dimensions(String.to_existing_atom(c["name"]))
  if dims != c, do: raise("Native pose dimensions mismatch: #{inspect(c)}")
end

decode = fn value ->
  <<number::float-64>> = Base.decode16!(value, case: :lower)
  number
end

bits = fn tuple ->
  for value <- Tuple.to_list(tuple), do: Base.encode16(<<value::float-64>>, case: :lower)
end

for c <- native["geometry"] do
  position = c["position"] |> Enum.map(decode) |> List.to_tuple()
  {:ok, actual} = PlayerPose.geometry(String.to_existing_atom(c["pose"]), position)

  for {field, key} <- [box: "box", fit_box: "fit_box", eye: "eye"] do
    if bits.(Map.fetch!(actual, field)) != c[key],
      do: raise("Native pose geometry mismatch: #{inspect(c)} / #{field}")
  end
end

keys = [:sleeping, :swimming, :fall_flying, :spin_attack, :shift, :flying, :spectator, :passenger]
fit_poses = [:standing, :fall_flying, :sleeping, :swimming, :spin_attack, :crouching]

for c <- native["cases"] do
  values =
    for {key, bit} <- Enum.with_index(keys),
        into: %{},
        do: {key, (c["intent"] &&& 1 <<< bit) != 0}

  fits =
    for {pose, bit} <- Enum.with_index(fit_poses),
        into: %{},
        do: {pose, (c["fits"] &&& 1 <<< bit) != 0}

  current = String.to_existing_atom(c["current"])
  {:ok, selected, queries} = PlayerPose.select(current, struct!(PlayerPose, values), fits)

  if Atom.to_string(selected) != c["selected"] or
       Enum.map(queries, &Atom.to_string/1) != c["queries"],
     do: raise("Native pose selection mismatch: #{inspect(c)}")
end

IO.puts(
  "PASS: 18 native default dimensions, 72 bit-exact box/eye cases and 65,536 ordered pose selections."
)
