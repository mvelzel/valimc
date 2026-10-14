alias Valimc.{GameMode, PlayerInteraction}
alias Valimc.Protocol.Packets
[input, output] = System.argv()
native = input |> File.read!() |> JSON.decode!()

packets =
  for c <- native["packets"] do
    {:ok, mode} = GameMode.parse(c["mode"])
    player = %{entity_id: 42, game_mode: GameMode.new(mode)}
    {_, body} = Packets.interaction_attributes(player)
    body = body |> IO.iodata_to_binary() |> Base.encode16(case: :lower)
    if body != c["body"], do: raise("Native interaction attributes differ")
    if PlayerInteraction.block_range(mode) != c["block_range"], do: raise("Block range differs")

    if PlayerInteraction.entity_range(mode) != c["entity_range"],
      do: raise("Entity range differs")

    %{mode: c["mode"], body: body}
  end

for c <- native["boxes"] do
  {:ok, mode} = GameMode.parse(c["mode"])
  eye = List.to_tuple(c["eye"])
  block = c["block"] |> Enum.map(&trunc/1) |> List.to_tuple()

  if PlayerInteraction.block_distance_squared(eye, block) != c["distance"],
    do: raise("Native block distance differs: #{inspect(c)}")

  if PlayerInteraction.within_block?(mode, eye, block) != c["within"],
    do: raise("Native strict reach boundary differs: #{inspect(c)}")
end

for c <- native["hits"] do
  block = c["block"] |> Enum.map(&trunc/1) |> List.to_tuple()

  cursor = Base.decode16!(c["cursor_hex"], case: :lower)

  if PlayerInteraction.valid_hit?(block, cursor) != c["valid"],
    do: raise("Native hit boundary differs: #{inspect(c)}")
end

File.write!(output, JSON.encode!(packets))

IO.puts(
  "PASS: Elixir interaction attributes, strict box distances and hit locations match native cases."
)
