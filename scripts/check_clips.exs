# Differential check of `Valimc.Physics.Clip` (VMC-031a, a bucket's ray) against FluidOracle's
# clips: per ray over a scene of blocks and fluids, with outline shapes and the fluid modes NONE
# and SOURCE_ONLY, the hit's cell, face and location, or the miss.
[filename] = System.argv()
facts = JSON.decode!(File.read!(filename))
alias Valimc.Physics.Clip

mismatches =
  for {scene, s} <- Enum.with_index(facts["scenes"]),
      cells = Map.new(scene["cells"], fn [x, y, z, state] -> {{x, y, z}, state} end),
      {[fx, fy, fz, tx, ty, tz, source, hit, x, y, z, face, lx, ly, lz], r} <-
        Enum.with_index(scene["rays"]),
      ours =
        Clip.clip(
          {fx, fy, fz},
          {tx, ty, tz},
          if(source, do: :source_only, else: :none),
          &cells[&1]
        ),
      vanilla = %{
        miss: hit == 0,
        position: {x, y, z},
        face: face,
        location: {lx * 1.0, ly * 1.0, lz * 1.0}
      },
      Map.take(ours, [:miss, :position, :face, :location]) != vanilla,
      do: {s, r, vanilla, ours}

views =
  for [pitch, yaw, x, y, z] <- facts["views"],
      Clip.view_vector(pitch, yaw) != {x * 1.0, y * 1.0, z * 1.0},
      do: {pitch, yaw, {x, y, z}, Clip.view_vector(pitch, yaw)}

unless views == [] do
  IO.puts("#{length(views)} view vectors differ; first: #{inspect(hd(views))}")
  System.halt(1)
end

unless mismatches == [] do
  [{s, r, vanilla, ours} | _] = mismatches

  IO.puts("""
  #{length(mismatches)} rays differ; first: scene #{s}, ray #{r}
    vanilla: #{inspect(vanilla)}
    ours:    #{inspect(ours)}\
  """)

  System.halt(1)
end

rays = facts["scenes"] |> Enum.map(&length(&1["rays"])) |> Enum.sum()

IO.puts(
  "PASS: #{rays} vanilla clips over #{length(facts["scenes"])} scenes hit, and " <>
    "#{length(facts["views"])} view vectors aim, as Valimc.Physics.Clip does."
)
