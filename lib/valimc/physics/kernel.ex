defmodule Valimc.Physics.Kernel do
  @moduledoc """
  The entity physics kernel (VMC-077l), in Rust (`valimc_core::physics`) over
  a `Valimc.World.View`. Live play makes three kinds of call: a player's
  move packet or resting tick in one call each (`player_move/5`,
  `player_rest/3`, VMC-077l2), a region owner's items in one call per tick
  (`items/3`), mobs' batched travel and initial fluid and eye samples
  (`fluids/2`, `eye_block/3`), and placement and spawn obstruction (`obstructs?/4`). The other
  functions reach the kernel's pieces one by one for the oracle checks; their
  NIFs exist only in dev, test and bench builds (the `parity` feature).

  Each call hands the kernel the published rows of the chunks around its
  boxes (or a supplied view's states); the kernel decodes only the sections
  it reads, against the block fact table installed at start. A cell the view
  cannot read answers `{:error, {:missing_block, position}}`: movement into
  chunks that are not loaded or generated fails closed, except a spectator's,
  which reads them as air (VMC-077v).

  Boxes are `{x0, y0, z0, x1, y1, z1}`, vectors `{x, y, z}`; contexts are
  `Valimc.Physics.CollisionContext`s; `extra` is `{entity_boxes, border}` with
  the border a `Valimc.Physics.BorderSnapshot` or nil.
  """
  alias Valimc.Native
  alias Valimc.Physics.{BorderSnapshot, CollisionContext}
  alias Valimc.Data.BlockFacts

  @none {[], nil}

  @doc "Extra colliders: entity boxes and the stationary world border (or nil)."
  def extra(entities \\ [], border \\ nil)
  def extra(entities, nil), do: {entities, nil}

  def extra(entities, %BorderSnapshot{} = border) do
    {:ok, bounds} = BorderSnapshot.bounds(border)
    {entities, bounds}
  end

  @doc """
  Whether `box` lies inside the world and its block scan (one block of halo)
  reads at most `cells` cells: the bound on a player's query.
  """
  def bounded?(box, cells \\ 1024)

  def bounded?({x0, y0, z0, x1, y1, z1}, cells)
      when abs(x0) < 30_000_000 and abs(x1) < 30_000_000 and abs(z0) < 30_000_000 and
             abs(z1) < 30_000_000 and abs(y0) <= 1_000_000 and abs(y1) <= 1_000_000 and
             x0 <= x1 and y0 <= y1 and z0 <= z1 do
    span = fn a, b -> floor(b + 1.0e-7) - floor(a - 1.0e-7) + 3 end
    span.(x0, x1) * span.(y0, y1) * span.(z0, z1) <= cells
  end

  def bounded?(_box, _cells), do: false

  @doc """
  `Entity.collide`: the movement `body` makes, with step-up up to `max_step`
  when `ground` (true, false, or a downward probe distance that decides it)
  holds and the move is blocked horizontally.
  """
  def move(view, body, movement, context, extra \\ @none, max_step \\ 0.0, ground \\ false) do
    region = body |> expand(movement) |> grow(max_step + 1.0)

    Native.physics_move(
      native(view, region),
      body,
      floats(movement),
      context(context),
      extra,
      max_step * 1.0,
      ground
    )
    |> case do
      {:ok, {actual, horizontal, vertical, below, stepped}} ->
        {:ok,
         %{
           actual: actual,
           horizontal: horizontal,
           vertical: vertical,
           below: below,
           stepped: stepped
         }}

      error ->
        error(error)
    end
  end

  @doc """
  Whether `box` meets a block, entity box or the border: `{:ok, boolean}`.
  `subject` is the mover's position for the border's closeness test (the
  box's centre when nil).
  """
  def colliding?(view, box, context, extra \\ @none, subject \\ nil) do
    with {:ok, [colliding]} <- colliding(view, [box], context, extra, subject),
         do: {:ok, colliding}
  end

  @doc "`colliding?/5` for several boxes of one mover at once."
  def colliding(view, boxes, context, extra \\ @none, subject \\ nil)
  def colliding(_view, [], _context, _extra, _subject), do: {:ok, []}

  def colliding(view, [first | _] = boxes, context, extra, subject) do
    region = Enum.reduce(boxes, &union/2)

    subject =
      case subject do
        {x, _, z} ->
          {x * 1.0, z * 1.0}

        nil ->
          {x0, _, z0, x1, _, z1} = first
          {(x0 + x1) / 2, (z0 + z1) / 2}
      end

    Native.physics_colliding(native(view, region), boxes, context(context), extra, subject)
    |> error()
  end

  @doc """
  Whether an eye at `eye` of `body` is in water and the block there
  (`updateFluidOnEyes` and its bubble column test): `{:ok, {water, state}}`.
  """
  def eye_block(view, body, eye) do
    case Native.physics_eyes(native(view, body), body, eye) do
      {:ok, {water, state}} -> {:ok, {water, state}}
      other -> error(other)
    end
  end

  @doc """
  The fluid cells `body` touches (scan order) and the water and lava depths:
  `{:ok, nil}` for a degenerate body.
  """
  def fluids(view, body) do
    case Native.physics_fluids(native(view, body), body) do
      {:ok, {water, lava, contacts}} ->
        {:ok,
         %{
           water: water,
           lava: lava,
           contacts:
             Enum.map(contacts, fn {position, kind, amount, height, {source, falling}, depth} ->
               %{
                 position: position,
                 fluid: %{
                   kind: kind,
                   amount: amount,
                   height: height,
                   source: source,
                   falling: falling
                 },
                 depth: depth
               }
             end)
         }}

      other ->
        error(other)
    end
  end

  @doc "Whether the eye is under water and lava: `{:ok, nil | %{water, lava}}`."
  def eyes(view, body, eye) do
    case Native.physics_fluid_eyes(native(view, body), body, floats(eye)) do
      {:ok, {water, lava}} -> {:ok, %{water: water, lava: lava}}
      other -> error(other)
    end
  end

  @doc "The flow of the fluid at a position."
  def flow(view, {x, y, z} = position) do
    region = {x - 1.0, y - 1.0, z - 1.0, x + 2.0, y + 2.0, z + 2.0}
    Native.physics_flow(native(view, region), position) |> error()
  end

  @doc """
  The current's push on a body (`kind` `:player` averages flows, `:item`
  normalizes their sum): `{:ok, nil | %{depths: %{water, lava}, velocity}}`.
  """
  def current(view, body, velocity, pushed \\ true, fast_lava \\ false, kind \\ :player) do
    case Native.physics_current(
           native(view, grow(body, 1.0)),
           body,
           floats(velocity),
           {pushed, fast_lava, kind == :item}
         ) do
      {:ok, {water, lava, velocity}} ->
        {:ok, %{depths: %{water: water, lava: lava}, velocity: velocity}}

      other ->
        error(other)
    end
  end

  @doc """
  The blocks a body passes from `from` to `to` (`body` the deflated
  destination box), at most `stop`: `{:ok, %{visits: [{position, step}],
  complete: boolean}}` or `{:error, :body_sweep_limit}`.
  """
  def sweep(from, to, body, stop \\ 512) do
    case Native.physics_sweep(floats(from), floats(to), body, stop) do
      {:ok, {visits, complete}} ->
        {:ok,
         %{visits: Enum.map(visits, fn {x, y, z, s} -> {{x, y, z}, s} end), complete: complete}}

      {:error, :limit} ->
        {:error, :body_sweep_limit}
    end
  end

  @doc "Whether `state`'s collision shape at `position` meets any of `bodies`."
  def obstructs?(state, position, context, bodies) do
    BlockFacts.install!()
    Native.physics_obstructs(state, position, context(context), bodies)
  end

  @doc "World-space collision cells from the movement kernel's generated shapes and entity context."
  def collision_boxes(state, position, ctx) do
    BlockFacts.install!()
    Native.physics_collision_boxes(state, position, context(ctx))
  end

  @doc """
  The velocity after a move that ended `moved_y` vertically (`Entity.move`
  restitution and the landing block's bounce): `%{velocity, bounced}`.
  `response` holds `x_collision`, `z_collision`, `vertical_collision`,
  `below`, `suppress_bounce`, `block_suppresses_bounce`,
  `entity_bounciness`, `block_bounciness`, `gravity` (0.08) and `air_drag`
  (0.98); missing collisions and bounces are false and 0.
  """
  def respond(velocity, moved_y, response) do
    r = &Map.get(response, &1, &2)

    {velocity, bounced} =
      Native.physics_respond(
        floats(velocity),
        moved_y * 1.0,
        {r.(:x_collision, false), r.(:z_collision, false), r.(:vertical_collision, false),
         r.(:below, false)},
        {r.(:suppress_bounce, false), r.(:block_suppresses_bounce, false),
         r.(:entity_bounciness, 0.0) * 1.0, r.(:block_bounciness, 0.0) * 1.0},
        {r.(:gravity, 0.08) * 1.0, r.(:air_drag, 0.98) * 1.0}
      )

    %{velocity: velocity, bounced: bounced}
  end

  @doc """
  One tick for each item `{position, velocity, on_ground, no_gravity}`:
  `{:ok, results}` in order, each `{:ok, position, velocity, on_ground, lava,
  fire_contacts, in_water}`: whether it began in lava; its fire, lava, water
  and cactus contacts; its water flag after the final fluid update. Other
  results are `:inside`, `{:unreadable, position}` or `:limit`.
  """
  def items(_view, [], _border), do: {:ok, []}

  def items(view, items, border) do
    region =
      items
      |> Enum.map(fn {{x, y, z}, velocity, _, _} ->
        expand({x - 1.0, y - 2.0, z - 1.0, x + 1.0, y + 2.0, z + 1.0}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    cells = Enum.reduce(items, 0, fn {_, velocity, _, _}, sum -> sum + scan_cells(velocity) end)
    Native.dispatch(:physics_items, cells, [native(view, region), items, bounds, true])
  end

  @doc """
  One tick for each experience orb `{position, velocity, on_ground, target,
  draws}`, `target` the followed player's position at half its eye height or
  nil, `draws` four 24-bit `nextFloat` draws for a jump in lava: results as
  `items/3`'s.
  """
  def orbs(_view, [], _border), do: {:ok, []}

  def orbs(view, orbs, border) do
    region =
      orbs
      |> Enum.map(fn {{x, y, z}, velocity, _, _, _} ->
        expand({x - 1.0, y - 2.0, z - 1.0, x + 1.0, y + 2.0, z + 1.0}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    cells = Enum.reduce(orbs, 0, fn {_, velocity, _, _, _}, sum -> sum + scan_cells(velocity) end)
    Native.dispatch(:physics_orbs, cells, [native(view, region), orbs, bounds])
  end

  @doc """
  A tick's moving-block pushes (VMC-048b) on `bodies`: `pushes` are the
  moving pistons' ticks in order, `{position, moving, progress, state,
  landed?}` (`moving` the block entity before it, as
  `Valimc.Blocks.MovingPistons.unpack/1` gives it, `progress` its new one,
  `state` the cell's before; a landed one pushes nothing), over the world
  after them all; each body `{feet, {half_width, height}, velocity, {on_ground,
  max_step, simulates?, ignored?}, {bounciness, suppresses_bounce?, living?,
  gravity, air_drag}}`. `{:ok, [{feet, velocity, on_ground, pushed?}]}` in
  order. `authoritative` controls ground-state authority separately from a
  body's simulation eligibility; hosted players simulate with it set to false.
  """
  def pistons(view, pushes, bodies, border, authoritative \\ true)
  def pistons(_view, _pushes, [], _border, _authoritative), do: {:ok, []}

  def pistons(view, pushes, bodies, border, authoritative) do
    regions =
      for(
        {{x, y, z}, _, _, _, _} <- pushes,
        do: {x - 3.0, y - 3.0, z - 3.0, x + 4.0, y + 4.0, z + 4.0}
      ) ++
        for {{x, y, z}, {w, h}, _, _, _} <- bodies,
            do: {x - w - 2.0, y - 2.0, z - w - 2.0, x + w + 2.0, y + h + 2.0, z + w + 2.0}

    packed =
      for {position, moving, progress, state, landed} <- pushes,
          into: <<>>,
          do:
            <<Valimc.Blocks.MovingPistons.pack({position, moving})::binary, progress::float-32,
              state::16, if(landed, do: 1, else: 0)>>

    states =
      {Valimc.Data.Blocks.default_state("slime_block"),
       Valimc.Data.Blocks.default_state("honey_block")}

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    Native.physics_pistons(
      native(view, Enum.reduce(regions, &union/2)),
      packed,
      bodies,
      states,
      bounds,
      authoritative
    )
  end

  @doc """
  One tick of every mob of an owner (VMC-015i), each a map as
  `Valimc.Entity.MobMotion.kernel/2` makes it, `players` the `{feet, box}`
  of the players that push them: `{:ok, results}` in order, each `{:ok,
  ticked}` or `{:error, reason}`.
  """
  def mobs(_view, [], _players, _border), do: {:ok, []}

  def mobs(view, mobs, players, border) do
    region =
      mobs
      |> Enum.map(fn %{position: {x, y, z}, size: {width, height, _}, velocity: velocity} ->
        half = width / 2 + 2.0
        expand({x - half, y - 2.0, z - half, x + half, y + height + 2.0, z + half}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    # A mob's tick scans about four times an item's cells (move, fluids twice,
    # footing, contacts) over its larger body.
    cells =
      Enum.reduce(mobs, 0, fn %{velocity: velocity}, sum -> sum + 4 * scan_cells(velocity) end)

    Native.dispatch(:physics_mobs, cells, [native(view, region), mobs, players, bounds])
  end

  @doc """
  Begin an owner's mob tick (VMC-043e): `mobs` (kernel maps) as they start
  it over `view`, pushed by `players` (`{feet, box}`), within `border`.
  The ticker keeps the view and the mobs' motion while the owner steps each
  mob (`mob_step/3`) and ends it (`mobs_finish/1`).
  """
  def mobs_begin(view, mobs, players, border, colliders \\ []) do
    region =
      mobs
      |> Enum.map(fn %{position: {x, y, z}, size: {width, height, _}, velocity: velocity} ->
        half = width / 2 + 2.0
        expand({x - half, y - 2.0, z - half, x + half, y + height + 2.0, z + half}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    cells = native(view, region)
    units = if match?({:states, _}, cells), do: div(byte_size(elem(cells, 1)), 14), else: 0
    Native.dispatch(:physics_mobs_begin, units, [cells, mobs, players, bounds, colliders])
  end

  @doc """
  Mob `index`'s tick with `mob` (its AI's input): `{result, pushed}`, the
  result `{:ok, ticked}` or an error (the mob keeps its state), and the mobs
  it pushed (`[{index, velocity}]`).
  """
  def mob_step(ticker, index, %{velocity: velocity} = mob),
    do: Native.dispatch(:physics_mobs_step, 4 * scan_cells(velocity), [ticker, index, mob])

  @doc "Fluid depths and eye state before AI, from the mob ticker's immutable view."
  def mob_sense(ticker, {x0, y0, z0, x1, y1, z1} = body, eye) do
    # Include the cells just above contacts and the eye's sturdy-face test.
    cells =
      (floor(x1) - floor(x0) + 2) * (floor(y1) - floor(y0) + 3) *
        (floor(z1) - floor(z0) + 2)

    Native.dispatch(:physics_mobs_sense, cells, [ticker, body, floats(eye)]) |> error()
  end

  @doc "A solid family's box and position after its owner's changes in this tick."
  def mob_collider(ticker, index, position, box),
    do: Native.physics_mobs_collider(ticker, index, floats(position), box)

  @doc "A lid's external move of a mob, without running its own tick."
  def mob_displace(ticker, index, mob, delta),
    do: Native.physics_mobs_displace(ticker, index, mob, floats(delta))

  @doc "Observe a goal's own move with live collision, without advancing the ticker."
  def mob_goal_position(ticker, index, mob),
    do: Native.physics_mobs_goal_position(ticker, index, mob)

  @doc "An external move with ordinary collision, without piston limits or exemptions."
  def displace(
        view,
        {{x, y, z}, {w, h}, _, {_, step, _, _}, _} = body,
        delta,
        boxes,
        border,
        authoritative \\ true
      ) do
    region =
      {x - w, y, z - w, x + w, y + h, z + w}
      |> expand(delta)
      |> grow(2.0 + step)

    bounds = if border, do: elem(BorderSnapshot.bounds(border), 1)

    Native.physics_displace(
      native(view, region),
      body,
      floats(delta),
      boxes,
      bounds,
      authoritative
    )
  end

  @doc "Mob `index`'s motion as its tick ended (later pushes add to it)."
  def mob_velocity(ticker, index, velocity),
    do: Native.physics_mobs_velocity(ticker, index, floats(velocity))

  @doc "End the tick: the players push; every mob's motion for its next tick."
  def mobs_finish(ticker), do: Native.physics_mobs_finish(ticker)

  @doc """
  An explosion's reach (VMC-050a): the cells the rays of an explosion of
  `radius` at `center` reach (`{position, state}`, air included, sorted),
  drawing from a `LegacyRandomSource` seeded with `seed`, in a world of
  `height` cells from `min_y`. `{:ok, {cells, unreadable}}`, `unreadable`
  whether a ray stopped at a cell the view cannot read. Runs on a dirty
  scheduler.
  """
  def explosion(view, {x, y, z} = center, radius, seed, min_y, height) do
    reach = radius * 1.3 / 0.225 * 0.3 + 2.0
    region = {x - reach, y - reach, z - reach, x + reach, y + reach, z + reach}

    Native.physics_explosion(
      native(view, region),
      floats(center),
      radius * 1.0,
      seed,
      min_y,
      height
    )
  end

  @doc "How much of each box sees `center` (`getSeenPercent`): `{:ok, [exposure]}`."
  def exposure(_view, _center, []), do: {:ok, []}

  def exposure(view, {x, y, z} = center, boxes) do
    region = Enum.reduce(boxes, {x, y, z, x, y, z}, &union/2)
    Native.physics_exposure(native(view, region), floats(center), boxes)
  end

  @doc """
  One tick for each primed TNT or falling block `{position, velocity,
  on_ground, no_gravity, kind}` (kind `:tnt` or `:falling_block`): `{:ok,
  results}` in order, each `{:ok, position, velocity, on_ground, moved_y}`,
  `{:unreadable, position}` or `:limit`.
  """
  def block_bodies(_view, [], _border), do: {:ok, []}

  def block_bodies(view, bodies, border) do
    region =
      bodies
      |> Enum.map(fn {{x, y, z}, velocity, _, _, _} ->
        expand({x - 1.5, y - 2.0, z - 1.5, x + 1.5, y + 3.0, z + 1.5}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    cells =
      Enum.reduce(bodies, 0, fn {_, velocity, _, _, _}, sum -> sum + 8 * scan_cells(velocity) end)

    Native.dispatch(:physics_block_bodies, cells, [native(view, region), bodies, bounds])
  end

  @doc """
  One tick of each projectile (VMC-037o, `valimc_core::physics::projectile`):
  `{state, kind, size, random, owner}` with `state` `{position, velocity,
  {yaw, pitch}, age, {in_water, in_ground, left_owner}, last_state}`, `kind`
  `{:arrow, gravity}`, `{:throwable, gravity}`, `{:hurting, acceleration}` or
  `{:eye, target}`, `size` `{width, height}`, `random` three floats and
  `owner` its owner's network id or nil; `targets` the entities they may hit,
  `{id, position, box}`. `{:ok, results}` in order, each `{:ok, state, hit,
  {water, lava}, loosened}`, `{:unreadable, position}` or `:limit`; `hit` is
  nil, `{:block, location, face, cell, inside, border}`, `{:entity, id,
  location}` or (an arrow's) `{:entities, [{id, location}]}`.
  """
  def projectiles(view, projectiles, targets, border, fast_lava \\ false)
  def projectiles(_view, [], _targets, _border, _fast_lava), do: {:ok, []}

  def projectiles(view, projectiles, targets, border, fast_lava) do
    region =
      projectiles
      |> Enum.map(fn {{{x, y, z}, velocity, _, _, _, _}, _, {w, h}, _, _} ->
        reach = max(w, h) + 3.0
        expand({x - reach, y - reach, z - reach, x + reach, y + reach, z + reach}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    # A ray and two fluid scans over the path, as an item tick's cells.
    cells =
      Enum.reduce(projectiles, 0, fn {{_, velocity, _, _, _, _}, _, _, _, _}, sum ->
        sum + 2 * scan_cells(velocity)
      end)

    # Entity intersection scans grow with the owning group's target count.
    units = cells + length(projectiles) * length(targets)

    Native.dispatch(:physics_projectiles, units, [
      native(view, region),
      projectiles,
      targets,
      bounds,
      fast_lava
    ])
  end

  # The cells one item tick scans, about: its movement's (0.25 blocks plus the
  # velocity, and the scan's halo) and its fluid and clearance scans.
  defp scan_cells({x, y, z}),
    do: 64 + (trunc(abs(x) + 0.25) + 3) * (trunc(abs(y) + 0.29) + 3) * (trunc(abs(z) + 0.25) + 3)

  @doc false
  # A shape from fact JSON (`axes`, `sizes`, hex `bits`) as the kernel takes it
  # (oracle checks).
  def shape(%{"axes" => axes, "sizes" => sizes, "bits" => bits}),
    do:
      {Enum.map(axes, fn a -> Enum.map(a, &(&1 * 1.0)) end), sizes,
       Base.decode16!(bits, case: :lower)}

  @doc "A context as the kernel takes it."
  def context(%CollisionContext{} = c) do
    {{c.kind == :entity, c.bottom * 1.0, c.descending, c.placement},
     {c.entity_present, c.fall_distance * 1.0, c.falling_block, c.powder_snow_walkable}}
  end

  @doc "The kernel's view of `view` for cells around `region` (installing the facts once)."
  def native(view, region) do
    BlockFacts.install!()
    Valimc.Physics.Cells.cells(view, region)
  end

  @doc "A kernel result, an unreadable cell reported as a missing block."
  def error({:error, {:unreadable, position}}), do: {:error, {:missing_block, position}}
  def error(other), do: other

  defp floats({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

  defp expand({x0, y0, z0, x1, y1, z1}, {dx, dy, dz}),
    do:
      {x0 + min(dx, 0), y0 + min(dy, 0), z0 + min(dz, 0), x1 + max(dx, 0), y1 + max(dy, 0),
       z1 + max(dz, 0)}

  defp grow({x0, y0, z0, x1, y1, z1}, d), do: {x0 - d, y0 - d, z0 - d, x1 + d, y1 + d, z1 + d}

  defp union({a0, b0, c0, d0, e0, f0}, {a1, b1, c1, d1, e1, f1}),
    do: {min(a0, a1), min(b0, b1), min(c0, c1), max(d0, d1), max(e0, e1), max(f0, f1)}
end
