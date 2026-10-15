alias Valimc.Protocol.{Data, Packets}
alias Valimc.World
alias Valimc.World.Region
[output] = System.argv()
{:ok, owner} = World.owner({700, 700})
World.subscribe(MapSet.new([{700, 700}]), MapSet.new())

measure = fn edits, mode ->
  {:ok, initial} = Region.observe_blocks(owner, [])
  cleared = Map.new(edits, fn {pos, _} -> {pos, 0} end)
  {:ok, _} = Region.set_blocks(owner, initial.revision, cleared)

  receive do
    {:event, {:block_batch, _}} -> :ok
  after
    1000 -> raise "Missing reset publication"
  end

  {:ok, before} = Region.observe_blocks(owner, [])
  start = System.monotonic_time(:microsecond)

  frames =
    case mode do
      :single ->
        Enum.map(edits, fn {pos, block} ->
          :ok = World.set_block(pos, block)

          receive do
            {:event, {:block, ^pos, ^block}} ->
              Packets.frame(Packets.block(pos, block), 256)
          after
            1000 -> raise "Missing single-block publication"
          end
        end)

      :batch ->
        {:ok, _} = Region.set_blocks(owner, before.revision, edits)

        receive do
          {:event, {:block_batch, frames}} -> Enum.map(frames, &elem(&1, 1))
        after
          1000 -> raise "Missing batch publication"
        end
    end

  elapsed = System.monotonic_time(:microsecond) - start
  for {pos, block} <- edits, do: true = World.get_block(pos) == block

  %{
    mode: mode,
    updates: map_size(edits),
    publication_events: if(mode == :single, do: map_size(edits), else: 1),
    packets: length(frames),
    bytes: IO.iodata_length(frames),
    elapsed_us: elapsed
  }
end

results =
  for count <- [64, 256, 4096] do
    edits =
      for n <- 0..(count - 1),
          into: %{},
          do:
            {{700 * 128 + div(n, 256), 64 + rem(n, 16), 700 * 128 + rem(div(n, 16), 16)},
             Data.block("stone")}

    %{
      single: measure.(edits, :single),
      batch: measure.(edits, :batch),
      edits: Enum.map(edits, fn {{x, y, z}, block} -> [x, y, z, block] end)
    }
  end

record = %{
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  schedulers: System.schedulers_online(),
  scope:
    "Single owner/fast local subscriber; same logical final edits, no network/survival/cross-server speed claim. Preparation, commit and publication included; singles drain each event.",
  source_sha256: :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower),
  implementation_sha256:
    Map.new(
      Path.wildcard("lib/**/*.ex") ++ ["priv/protocol/blocks.json", "priv/protocol/packets.json"],
      fn path ->
        {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
      end
    ),
  results: results
}

File.write!(output, JSON.encode!(record))
for %{single: single, batch: batch} <- results, do: IO.inspect(%{single: single, batch: batch})
