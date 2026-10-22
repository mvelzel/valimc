alias Valimc.Native
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
keys = ~w(water lava threshold on_ground jump shift flying)a
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end
float = fn v -> if is_number(v), do: v * 1.0, else: v end

for c <- cases do
  f = Map.new(keys, &{&1, float.(Map.fetch!(c, Atom.to_string(&1)))})
  initial = c["initial"] |> Enum.map(float) |> List.to_tuple()
  {:ok, {velocity, ground_jump}} = Native.physics_player_parity(:fluid_controls, {initial, f})

  unless bits.(velocity) == bits.(List.to_tuple(c["velocity"])) and
           ground_jump == c["ground_jump"],
         do:
           raise("Native fluid input mismatch #{inspect(c)} #{inspect({velocity, ground_jump})}")
end

IO.puts("PASS: #{length(cases)} native fluid input/jump and normalized sink cases.")
