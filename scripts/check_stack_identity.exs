alias Valimc.Protocol.ItemStack
[path] = System.argv()
fixtures = :json.decode(File.read!(path))

for fixture <- fixtures do
  decode = fn key, mode ->
    {:ok, stack} = fixture[key] |> Base.decode16!(case: :lower) |> ItemStack.decode(mode)
    stack
  end

  a = decode.("a", :trusted)
  b = decode.("b", :trusted)
  true = a == decode.("a_untrusted", :untrusted)
  true = b == decode.("b_untrusted", :untrusted)

  if ItemStack.same_item?(a, b) != fixture["same"],
    do: raise("Effective identity differs from Mojang: #{fixture["name"]}")
end

IO.puts(
  "PASS: Elixir effective identity matches #{length(fixtures)} Mojang raw-patch equality cases"
)
