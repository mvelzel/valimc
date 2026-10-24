alias Valimc.World.{Blocks, BlockRules}
BlockRules.native()
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 384, do: raise("Incomplete turtle-egg placement fixtures")

sections =
  for key <- [{0, 0}, {1, 0}], into: %{} do
    {:ok, blocks} = Blocks.new(key)
    {key, blocks}
  end

events =
  for row <- cases, reduce: 0 do
    count ->
      key = {div(row["x"], 128), 0}
      blocks = sections[key]
      siblings = for {other, resource} <- sections, other != key, do: resource
      pos = {row["x"], 64, 8}
      :ok = Blocks.put(blocks, %{pos => row["state"], {row["x"], 63, 8} => row["support"]})
      result = BlockRules.run(blocks, siblings, %{changes: %{pos => row["old"]}}, [])
      actual = for {{x, y, z}, kind, data} <- result.events, do: [x, y, z, kind, data]
      if actual != row["events"], do: raise("egg placement #{inspect(row)}: #{inspect(actual)}")
      count + length(actual)
  end

184 = events
IO.puts("PASS: 384 native turtle-egg changes and 184 placement events across section lines")
