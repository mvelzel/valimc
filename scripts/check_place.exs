# VMC-053: `/place` changes what vanilla's `PlaceCommand` placements change
# (PlaceOracle): per case, the area's terrain of seed 20261020 as column
# images, the placement with the case's level random seed, and the changed
# blocks compared with vanilla's.
[cases_path] = System.argv()
cases = cases_path |> File.read!() |> JSON.decode!()

{:ok, _} = Application.ensure_all_started(:crypto)
alias Valimc.Native

{:ok, state} = Valimc.Worldgen.new(20_261_020)
source = "minecraft:overworld"
protocol_biomes = Valimc.World.Generator.protocol_biomes()
base = for _ <- 1..384, do: 0

columns = :ets.new(:columns, [:set])

column = fn chunk ->
  case :ets.lookup(columns, chunk) do
    [{_, image}] ->
      image

    [] ->
      {x, z} = chunk
      {:ok, cell} = Native.gen_terrain(state, source, nil, x, z)
      {:ok, full} = Native.gen_full(state, cell, protocol_biomes)
      :ets.insert(columns, {chunk, full.image})
      full.image
  end
end

{failures, placed} =
  Enum.reduce(cases, {[], 0}, fn c, {failures, placed} ->
    [x0, z0, size] = c["area"]
    chunks = for dz <- 0..(size - 1), dx <- 0..(size - 1), do: {x0 + dx, z0 + dz}
    input = for {x, z} = chunk <- chunks, do: {x, z, column.(chunk)}
    [px, py, pz] = c["pos"]
    spec = {c["kind"], c["names"], c["depth"], c["integrity"] * 1.0, c["strict"]}
    seed = String.to_integer(c["seed"])

    {ours, changed} =
      try do
        case Native.worldgen_place(state, source, spec, {px, py, pz}, input, base, seed) do
          {:ok, nil} ->
            {false, []}

          {:ok, {blocks, _entities, _mobs}} ->
            {true, for({{x, y, z}, s} <- blocks, do: "#{x} #{y} #{z} #{s}")}
        end
      rescue
        # A placement the generator cannot run raises with the reason.
        error in ErlangError -> {{:error, error.original}, []}
      end

    want = MapSet.new(c["changed"])
    got = MapSet.new(changed)

    if ours == c["placed"] and got == want do
      {failures, placed + if(ours, do: 1, else: 0)}
    else
      failure = %{
        case: {c["kind"], c["names"], c["pos"], c["seed"]},
        placed: {c["placed"], ours},
        missing: want |> MapSet.difference(got) |> Enum.take(4),
        extra: got |> MapSet.difference(want) |> Enum.take(4),
        counts: {MapSet.size(want), MapSet.size(got)}
      }

      {[failure | failures], placed}
    end
  end)

if failures != [] do
  for f <- Enum.reverse(failures), do: IO.inspect(f, limit: :infinity)
  IO.puts("FAIL: #{length(failures)} of #{length(cases)} /place cases differ")
  System.halt(1)
end

IO.puts("PASS: #{length(cases)} /place cases equal vanilla's (#{placed} placed)")
