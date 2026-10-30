defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of a section's mobs (VMC-081d): every mob takes its turn in its
  section's `MobSection` resource, one at a time in id order as vanilla's
  level ticks them (fluids, the base tick, its family's AI, the kernel's
  move, vitals, daylight), over what the section keeps resident or an
  oracle's scene. Only what changed comes back.
  """
  alias Valimc.Entity.NativeMobs

  @doc """
  One tick of a section (`NativeMobs.tick/8`): `source` `{:world, world}`
  or an oracle's `{:scene, view, level, players, region}`, `mask` its
  simulated chunks (or `:all`), `random` the section's level random and
  `extra` its extras (`Native.mob_section_tick/6`). `{random, %{moved,
  changes}}`: the level random after the tick and what changed of the
  mobs (`Store.native_tick/3` takes it).
  """
  def native_tick(native, source, tick, mask, random, extra) do
    units = Map.get(extra, :units, 16)

    {random, moved, changes} = NativeMobs.tick(native, source, tick, mask, random, extra, units)

    {random, %{moved: moved, changes: changes}}
  end

  @doc """
  A step for every mob of `mobs` (`[{id, entry}]` in id order, each in
  section `native`) after one tick over a supplied view (oracle checks and
  tests): `native_tick/6` over `{:scene, ...}`. `env` is what the turns read
  beyond the ticker: `%{region, level, players, random}`, and where the
  scene has them `items` (sensed rows) and `loot_seeds` (a piglin's barter).
  A step's body is the mob's `NativeBody` row after the tick. Returns
  `{steps, env}`, `env`'s random after the tick and its items less what the
  mobs picked up.
  """
  def native_steps(view, mobs, native, env) do
    ids = for {id, _} <- mobs, do: id
    items = Map.get(env, :items, [])

    source =
      {:scene, Valimc.Physics.Kernel.native(view, scene_region(mobs)), env.level, env.players,
       env.region}

    extra = %{items: items, only: ids}

    extra =
      case Map.get(env, :loot_seeds) do
        seeds when is_list(seeds) -> Map.put(extra, :loot_seeds, seeds)
        _ -> extra
      end

    {random, out} = native_tick(native, source, nil, :all, env.random, extra)

    changes =
      Map.new(out.changes, fn {id, _, events, effects, _} -> {id, {events, effects}} end)

    steps =
      for id <- ids do
        {position, row, idle, _lived} = NativeMobs.body(native, id)
        {events, effects} = Map.get(changes, id, {[], []})

        step = %{
          id: id,
          revision: 0,
          position: position,
          body: row,
          events: events,
          effects: effects,
          native: true,
          outside: false
        }

        if row.idle != nil, do: Map.put(step, :idle, idle), else: step
      end

    # The items the mobs took have fewer for the next tick.
    taken =
      for step <- steps,
          {:pickup, {:item, uuid}, n} <- step.effects,
          reduce: %{},
          do: (acc -> Map.update(acc, uuid, n, &(&1 + n)))

    items = for i <- items, do: %{i | count: i.count - Map.get(taken, i.uuid, 0)}
    {steps, %{env | random: random} |> Map.put(:items, items)}
  end

  # The cells a scene's mobs read: their boxes and moves, two blocks around.
  defp scene_region(mobs) do
    mobs
    |> Enum.map(fn {_, %{entity: e, body: body}} ->
      {width, height, _} = body.dimensions
      half = width / 2 + 2.0
      {vx, vy, vz} = body.velocity

      {e.x - half + min(vx, 0), e.y - 2.0 + min(vy, 0), e.z - half + min(vz, 0),
       e.x + half + max(vx, 0), e.y + height + 2.0 + max(vy, 0), e.z + half + max(vz, 0)}
    end)
    |> Enum.reduce(fn {a0, b0, c0, d0, e0, f0}, {a1, b1, c1, d1, e1, f1} ->
      {min(a0, a1), min(b0, b1), min(c0, c1), max(d0, d1), max(e0, e1), max(f0, f1)}
    end)
  end
end
