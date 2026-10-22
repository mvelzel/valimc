[path] = System.argv()
data = path |> File.read!() |> :json.decode()
bits = fn t -> for n <- Tuple.to_list(t), do: <<n::float-64>> end

Enum.each(data["cases"], fn c ->
  original = List.to_tuple(c["initial"])

  if bits.(original) != bits.(List.to_tuple(c["saved"])),
    do: raise("Native Motion save changed #{inspect(c)}")

  {:ok, actual} = Valimc.Player.Kinetics.restore_velocity(original)

  if bits.(actual) != bits.(List.to_tuple(c["loaded"])),
    do: raise("Native Motion load mismatch #{inspect(c)} #{inspect(actual)}")
end)

{:ok, zero} = Valimc.Player.Kinetics.restore_velocity({0.0, 0.0, 0.0})
if zero != List.to_tuple(data["missing"]), do: raise("Native missing Motion default mismatch")

IO.puts(
  "PASS: #{length(data["cases"])} native Motion save/load prefixes and zero migration default."
)
