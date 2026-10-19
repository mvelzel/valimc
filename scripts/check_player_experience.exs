alias Valimc.PlayerExperience
rows = System.argv() |> hd() |> File.read!() |> JSON.decode!()

Enum.each(rows, fn row ->
  xp =
    struct!(
      PlayerExperience,
      Map.new(row["before"], fn {k, v} -> {String.to_existing_atom(k), v} end)
    )

  {:ok, actual} = PlayerExperience.give(xp, row["amount"])
  expected = Map.from_struct(actual) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  if expected != row["after"], do: raise("XP mismatch: #{inspect(row)} => #{inspect(actual)}")
  {_, payload} = Valimc.Protocol.Packets.experience(actual)

  if Base.encode16(IO.iodata_to_binary(payload), case: :lower) != row["packet"],
    do: raise("packet mismatch")
end)

IO.puts("PASS: #{length(rows)} native player XP arithmetic/packet comparisons")

contacts = System.argv() |> hd() |> Kernel.<>(".contact.json") |> File.read!() |> JSON.decode!()

Enum.each(contacts, fn row ->
  box = {-0.3, 64.0, -0.3, 0.3, 64 + row["height"], 0.3}
  actual = Valimc.World.ExperienceTransfers.contact?(box, List.to_tuple(row["at"]))
  if actual != row["contact"], do: raise("XP contact differs: #{inspect(row)}")
end)

IO.puts("PASS: #{length(contacts)} native XP AABB contacts")
