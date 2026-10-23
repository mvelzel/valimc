# Differential check of what moving blocks do to entities (VMC-048b,
# `valimc_core::physics::piston`) against PistonOracle's push scenes: per block entity phase,
# each item's and armor stand's feet, velocity (bit for bit) and ground after the moving pistons
# that ticked pushed them (`moveCollidedEntities`, `moveStuckEntities`, the piston mover's
# `Entity.move`), over the world as the phase left it.
[file] = System.argv()
facts = JSON.decode!(File.read!(file))
Valimc.Data.BlockFacts.install!()

# Slime, honey, and the moving piston a block yet to tick stands in.
states =
  {Valimc.Data.Blocks.default_state("slime_block"),
   Valimc.Data.Blocks.default_state("honey_block"),
   Valimc.Data.Blocks.default_state("moving_piston")}

double = fn hex ->
  <<v::float-64>> = <<String.to_integer(hex, 16)::64>>
  v
end

bits = fn v -> Base.encode16(<<v::float-64>>, case: :lower) end

body = fn [kind, x, y, z, vx, vy, vz, ground] ->
  {kind, {double.(x), double.(y), double.(z)}, {double.(vx), double.(vy), double.(vz)}, ground}
end

moving = fn [x, y, z, moved, d, e, s, p | _] -> {{x, y, z}, moved, d, e == 1, s == 1, p} end

{failures, phases, moved} =
  for {scene, i} <- Enum.with_index(facts["scenes"]),
      step <- scene["steps"],
      reduce: {[], 0, 0} do
    {failures, phases, moved} ->
      before = Enum.map(step["before"], body)

      {:ok, ours} =
        Valimc.Native.piston_pushes(
          for([x, y, z, s] <- step["cells"], do: {x, y, z, s}),
          Enum.map(step["moving"], moving),
          Enum.map(step["ticking"], moving),
          before,
          states
        )

      ours =
        for {kind, {x, y, z}, {vx, vy, vz}, ground} <- ours,
            do: [kind, bits.(x), bits.(y), bits.(z), bits.(vx), bits.(vy), bits.(vz), ground]

      count = Enum.count(Enum.zip(step["before"], step["after"]), fn {b, a} -> b != a end)

      if ours == step["after"],
        do: {failures, phases + 1, moved + count},
        else:
          {[{i, step["t"], step["before"], step["after"], ours} | failures], phases + 1,
           moved + count}
  end

unless failures == [] do
  {scene, t, before, vanilla, ours} = List.last(failures)

  IO.puts("""
  #{length(failures)} of #{phases} phases differ; first: scene #{scene}, tick #{t}
    before:  #{inspect(before)}
    vanilla: #{inspect(vanilla)}
    ours:    #{inspect(ours)}\
  """)

  System.halt(1)
end

IO.puts(
  "PASS: #{phases} block entity phases of #{length(facts["scenes"])} vanilla push scenes move " <>
    "#{moved} items and armor stands as the kernel does, bit for bit"
)
