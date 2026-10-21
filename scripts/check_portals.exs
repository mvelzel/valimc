# VMC-026b2: nether portal shapes, fire placement, portal rectangles, relative
# positions, the closest portal search and portal creation equal vanilla's
# (PortalOracle) over the oracle's levels.
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()
alias Valimc.Portal.{Fire, Forcer, Shape}

air = Valimc.Registry.Blocks.default_state("air")
reader = fn blocks -> fn pos -> Map.get(blocks, pos, air) end end
to_pos = fn [x, y, z] -> {x, y, z} end
level = fn rows -> Map.new(rows, fn [x, y, z, state] -> {{x, y, z}, state} end) end

axis = fn
  "x" -> :x
  "z" -> :z
end

shape_json = fn %Shape{} = s ->
  {x, y, z} = s.bottom_left

  %{
    "axis" => Atom.to_string(s.axis),
    "bottom_left" => [x, y, z],
    "width" => s.width,
    "height" => s.height,
    "portal_blocks" => s.portal_blocks,
    "complete" => Shape.complete?(s)
  }
end

# Bounds of a vanilla `WorldBorder` with a centre and size (no lerp).
bounds = fn %{"center_x" => cx, "center_z" => cz, "size" => size} ->
  limit = 29_999_984.0
  half = size / 2.0

  {max(cx - half, -limit), max(cz - half, -limit), min(cx + half, limit), min(cz + half, limit)}
end

failures = []

failures =
  for {%{"min_y" => min_y, "blocks" => rows, "queries" => queries}, i} <-
        Enum.with_index(facts["shapes"]),
      read = reader.(level.(rows)),
      %{"pos" => pos, "axis" => preferred} = query <- queries,
      pos = to_pos.(pos),
      empty =
        (case Shape.find_empty(read, pos, axis.(preferred), min_y) do
           {:ok, s} -> shape_json.(s)
           :none -> nil
         end),
      any = shape_json.(Shape.find_any(read, pos, axis.(preferred), min_y)),
      {empty, any} != {query["empty"], query["any"]},
      reduce: failures,
      do: (acc -> [{:shape, i, pos, {empty, query["empty"]}, {any, query["any"]}} | acc])

dimension = fn
  "minecraft:overworld" -> :overworld
  "minecraft:the_nether" -> :the_nether
  "minecraft:the_end" -> :the_end
end

failures =
  for {%{"blocks" => rows, "pos" => pos, "state" => want, "dimension" => d} = c, i} <-
        Enum.with_index(facts["fires"]),
      read = reader.(level.(rows)),
      pos = to_pos.(pos),
      min_y = if(d == "minecraft:overworld", do: -64, else: 0),
      reduce: failures do
    acc ->
      acc =
        if Fire.state(read, pos) == want,
          do: acc,
          else: [{:fire_state, i, Fire.state(read, pos), want} | acc]

      Enum.reduce(c["queries"], acc, fn %{"facing" => facing, "placeable" => placeable}, acc ->
        got = Fire.placeable?(read, pos, String.to_atom(facing), dimension.(d), min_y)
        if got == placeable, do: acc, else: [{:fire, i, facing, got, placeable} | acc]
      end)
  end

rect_json = fn {{x, y, z}, a, b} -> %{"min" => [x, y, z], "axis1" => a, "axis2" => b} end

failures =
  for {%{"blocks" => rows, "center" => center, "axis" => a, "result" => want}, i} <-
        Enum.with_index(facts["rectangles"]),
      blocks = level.(rows),
      center = to_pos.(center),
      state = blocks[center],
      got =
        rect_json.(
          Forcer.largest_rectangle(
            center,
            axis.(a),
            21,
            :y,
            21,
            &(Map.get(blocks, &1, air) == state)
          )
        ),
      got != want,
      reduce: failures,
      do: (acc -> [{:rectangle, i, got, want} | acc])

failures =
  for {%{"rect" => r, "axis" => a, "pos" => [x, y, z], "dims" => [w, h], "result" => want}, i} <-
        Enum.with_index(facts["relative"]),
      rect = {to_pos.(r["min"]), r["axis1"], r["axis2"]},
      {gr, gu, gf} = Forcer.relative(rect, axis.(a), {x, y, z}, {w, h}),
      [gr, gu, gf] != want,
      reduce: failures,
      do: (acc -> [{:relative, i, [gr, gu, gf], want} | acc])

# MOTION_BLOCKING over the oracle's level: one above the top state that blocks
# motion or holds a fluid, else the bottom.
motion_blocking = fn blocks, min_y, height ->
  tops =
    Enum.reduce(blocks, %{}, fn {{x, y, z}, state}, acc ->
      if Valimc.Physics.HeightmapBlocks.opaque?(state, :motion_blocking) == {:ok, true},
        do: Map.update(acc, {x, z}, y, &max(&1, y)),
        else: acc
    end)

  fn x, z ->
    case tops[{x, z}] do
      nil -> min_y
      y -> min(y + 1, min_y + height)
    end
  end
end

failures =
  for {c, i} <- Enum.with_index(facts["create"]),
      blocks = level.(c["blocks"]),
      read = reader.(blocks),
      {min_y, height, logical} = {c["min_y"], c["height"], c["logical"]},
      got =
        Forcer.create(
          read,
          motion_blocking.(blocks, min_y, height),
          to_pos.(c["origin"]),
          axis.(c["axis"]),
          {min_y, height, logical},
          bounds.(c["border"])
        ),
      {rect, edits} =
        (case got do
           {:ok, {rect, edits}} ->
             {rect_json.(rect), for({{x, y, z}, s} <- edits, do: [x, y, z, s])}

           :error ->
             {nil, []}
         end),
      {rect, edits} != {c["rect"], c["edits"]},
      reduce: failures,
      do: (acc -> [{:create, i, rect, c["rect"], length(edits), length(c["edits"])} | acc])

failures =
  for {c, i} <- Enum.with_index(facts["closest"]),
      portals = for([x, y, z, s] <- c["portals"], do: {{x, y, z}, s}),
      radius = Forcer.radius(c["to_nether"]),
      got = Forcer.closest(portals, to_pos.(c["approx"]), radius, bounds.(c["border"])),
      ok =
        (case {got, c["result"]} do
           {:none, nil} ->
             true

           {{:ok, {x, y, z}}, want} when want != nil ->
             [x, y, z] == want or [x, y, z] in c["ties"]

           _ ->
             false
         end),
      not ok,
      reduce: failures,
      do: (acc -> [{:closest, i, got, c["result"]} | acc])

failures =
  for {c, i} <- Enum.with_index(facts["frames"]),
      read = reader.(level.(c["blocks"])),
      %{"pos" => pos, "interior" => want} <- c["queries"],
      got =
        (case Valimc.Portal.EndPortal.opening(read, to_pos.(pos)) do
           nil -> nil
           [{x, y, z} | _] -> [x, y, z]
         end),
      got != want,
      reduce: failures,
      do: (acc -> [{:frame, i, pos, got, want} | acc])

failures =
  for {c, i} <- Enum.with_index(facts["platforms"]),
      read = reader.(level.(c["blocks"])),
      got =
        for(
          {{x, y, z}, s} <- Valimc.Portal.EndPortal.platform(read, to_pos.(c["origin"])),
          do: [x, y, z, s]
        ),
      got != c["edits"],
      reduce: failures,
      do: (acc -> [{:platform, i, length(got), length(c["edits"])} | acc])

# Gateway exits: each step over the oracle's level as vanilla's changed it.
alias Valimc.Portal.Gateway

failures =
  for {c, i} <- Enum.with_index(facts["gateways"]), reduce: failures do
    acc ->
      blocks = level.(c["blocks"])
      entry = to_pos.(c["entry"])
      non_air = fn blocks -> for {pos, s} <- blocks, not Gateway.air?(s), do: pos end

      top = fn blocks, {cx, cz} ->
        ys =
          for {x, y, z} <- non_air.(blocks),
              Integer.floor_div(x, 16) == cx and Integer.floor_div(z, 16) == cz,
              do: y

        if ys == [], do: nil, else: Integer.floor_div(Enum.max(ys), 16) * 16 + 15
      end

      {tx, tz} =
        Gateway.tentative(entry, fn x, z -> top.(blocks, Gateway.chunk_of({x, z})) == nil end)

      chunk = Gateway.chunk_of({tx, tz})
      valid = Gateway.valid_spawn(reader.(blocks), chunk, top.(blocks, chunk))

      {spot, island} =
        case valid do
          nil ->
            origin = {floor(tx + 0.5), 75, floor(tz + 0.5)}
            {origin, Gateway.island(origin)}

          found ->
            {found, []}
        end

      blocks = Map.merge(blocks, Map.new(island))
      tallest = Gateway.tallest(reader.(blocks), spot, 16, true, {0, 255})
      {x, y, z} = tallest
      structure = Gateway.structure({x, y + 10, z})
      blocks = Map.merge(blocks, Map.new(structure))
      arrival = Gateway.arrival(reader.(blocks), {x, y + 10, z}, false, {0, 255})
      json = fn edits -> for {{x, y, z}, s} <- edits, do: [x, y, z, s] end

      pos_json = fn
        nil -> nil
        {x, y, z} -> [x, y, z]
      end

      got = %{
        "tentative" => [tx, tz],
        "valid" => pos_json.(valid),
        "island" => json.(island),
        "tallest" => pos_json.(tallest),
        "structure" => json.(structure),
        "arrival" => pos_json.(arrival)
      }

      want = Map.take(c, Map.keys(got)) |> Map.put_new("valid", nil)
      diff = for {k, v} <- got, v != want[k], do: {k, v, want[k]}
      if diff == [], do: acc, else: [{:gateway, i, Enum.take(diff, 2)} | acc]
  end

# Arrival poses (VMC-026c): position, velocity turned with the rotation, yaw and pitch.
alias Valimc.Portal.Motion
vec = fn [x, y, z] -> {x, y, z} end

failures =
  for {c, i} <- Enum.with_index(facts["motions"]), reduce: failures do
    acc ->
      relatives = if c["relatives"] == "into_end", do: Motion.into_end(), else: Motion.portal()

      source = %{
        position: vec.(c["position"]),
        delta: vec.(c["delta"]),
        yaw: c["yaw"],
        pitch: c["pitch"]
      }

      change = %{
        position: vec.(c["target"]),
        delta: {0.0, 0.0, 0.0},
        yaw: c["change_yaw"],
        pitch: c["change_pitch"]
      }

      got = Motion.absolute(source, change, relatives)

      want = %{
        position: vec.(c["result_position"]),
        delta: vec.(c["result_delta"]),
        yaw: c["result_yaw"] * 1.0,
        pitch: c["result_pitch"] * 1.0
      }

      if got == want, do: acc, else: [{:motion, i, got, want} | acc]
  end

if failures != [] do
  failures
  |> Enum.reverse()
  |> Enum.group_by(&elem(&1, 0))
  |> Enum.each(fn {kind, list} ->
    IO.puts("#{kind}: #{length(list)}")
    for failure <- Enum.take(list, 3), do: IO.inspect(failure, limit: 30)
  end)

  IO.puts("FAIL: #{length(failures)} portal differences")
  System.halt(1)
end

edits = facts["create"] |> Enum.map(&length(&1["edits"])) |> Enum.sum()

IO.puts(
  "PASS: #{length(facts["shapes"])} portal frames (#{6 * length(facts["shapes"])} shape queries), " <>
    "#{length(facts["fires"])} fire placements, #{length(facts["rectangles"])} rectangles, " <>
    "#{length(facts["relative"])} relative positions, #{length(facts["create"])} portal creations " <>
    "(#{edits} block sets in order), #{length(facts["closest"])} portal searches, " <>
    "#{length(facts["frames"])} end portal frames, #{length(facts["platforms"])} End platforms, " <>
    "#{length(facts["gateways"])} gateway exits and #{length(facts["motions"])} arrival poses equal vanilla's"
)
