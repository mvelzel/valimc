alias Valimc.PlayerInput, as: Input
alias Valimc.Protocol.Packets
[path] = System.argv()
native = path |> File.read!() |> JSON.decode!()

for c <- native["inputs"] do
  {:ok, buttons} = Input.decode(<<c["byte"]>>)
  {:ok, input} = Input.receive_input(Input.loaded(%Input{}), <<c["byte"]>>)

  actual =
    Enum.map(
      [:forward, :backward, :left, :right, :jump, :shift, :sprint],
      &Input.pressed?(input, &1)
    )

  if <<buttons>> != Base.decode16!(c["canonical"], case: :lower) or actual != c["booleans"],
    do: raise("Native input mismatch: #{inspect(c)}")
end

for c <- native["commands"] do
  {:ok, {id, action, data}} = Input.decode_command(Base.decode16!(c["payload"], case: :lower))

  if id != c["id"] or data != c["data"] or Atom.to_string(action) != c["action"],
    do: raise("Native command mismatch: #{inspect(c)}")
end

for c <- native["loads"] do
  input =
    Enum.reduce(List.duplicate(:tick, c["ticks"]), %Input{}, fn _, acc -> Input.tick(acc) end)

  if Input.loaded?(input) != c["loaded"] or
       Input.loaded?(Input.loaded(input)) != c["marked_loaded"],
     do: raise("Native load gate mismatch: #{inspect(c)}")
end

for c <- native["metadata"] do
  input = Input.loaded(%Input{})
  {:ok, input} = Input.receive_input(input, <<if(c["shift"], do: 32, else: 0)>>)
  {:ok, input} = Input.receive_command(input, <<0, if(c["sprint"], do: 1, else: 2), 0>>)
  {_, bytes} = Packets.player_flags(%{entity_id: 300, input: input})

  if input.shared_flags != c["flags"] or
       IO.iodata_to_binary(bytes) != Base.decode16!(c["payload"], case: :lower),
     do: raise("Native shared flags mismatch: #{inspect(c)}")
end

IO.puts(
  "PASS: native input/command semantics, load counters and exact shared-flag metadata bytes."
)
