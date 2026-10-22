defmodule Valimc.Physics.Kernel do
  @moduledoc """
  The entity physics kernel (VMC-077l), in Rust (`valimc_core::physics`) over
  a `Valimc.World.View`. Live play makes three kinds of call: a player's
  move packet or resting tick in one call each (`player_move/5`,
  `player_rest/3`, VMC-077l2), a region owner's items in one call per tick
  (`items/3`), and placement and spawn obstruction (`obstructs?/4`). The other
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
  `{:ok, results}` in order, each `{:ok, position, velocity, on_ground}`,
  `:inside`, `{:unreadable, position}` or `:limit`.
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
  One tick for each experience orb `{position, velocity, on_ground, target}`,
  `target` the followed player's position at half its eye height or nil:
  results as `items/3`'s.
  """
  def orbs(_view, [], _border), do: {:ok, []}

  def orbs(view, orbs, border) do
    region =
      orbs
      |> Enum.map(fn {{x, y, z}, velocity, _, _} ->
        expand({x - 1.0, y - 2.0, z - 1.0, x + 1.0, y + 2.0, z + 1.0}, velocity)
      end)
      |> Enum.reduce(&union/2)

    bounds =
      case border do
        nil -> nil
        border -> elem(BorderSnapshot.bounds(border), 1)
      end

    cells = Enum.reduce(orbs, 0, fn {_, velocity, _, _}, sum -> sum + scan_cells(velocity) end)
    Native.dispatch(:physics_orbs, cells, [native(view, region), orbs, bounds])
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
