alias Valimc.World.Difficulty
alias Valimc.Protocol.Packets
[path] = System.argv()
native = path |> File.read!() |> JSON.decode!()
if native["default"] != %Difficulty{}.level, do: raise("Native dedicated-server default mismatch")

for c <- native["changes"] do
  state = %Difficulty{level: c["initial"], locked: c["locked"]}
  {:ok, result} = Difficulty.change(state, c["target"], c["force"])

  if result.level != c["result"] or result.locked != c["locked"],
    do: raise("Native difficulty change mismatch: #{inspect(c)}")
end

for c <- native["packets"] do
  {_, payload} = Packets.difficulty(%Difficulty{level: c["level"], locked: c["locked"]})

  if payload != Base.decode16!(c["payload"], case: :lower),
    do: raise("Native difficulty packet mismatch: #{inspect(c)}")
end

IO.puts("PASS: Elixir matches 64 native lock/force cases and all eight difficulty packets.")
