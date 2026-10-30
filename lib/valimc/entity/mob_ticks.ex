defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of an owner's mobs (VMC-015i), one mob at a time in id order as
  vanilla's level ticks them, so each thinks with the mobs before it where
  they moved to (VMC-043e): its AI (`Valimc.AI.think_mob/4`, VMC-041a), its
  travel in the physics kernel (`Valimc.Physics.Kernel.mobs/4`: the move
  and jump controls, travel, collision, fluids, climbing, slowing blocks),
  its pushes (by the players it touches, and of the mobs it touches, which
  push it back), then its body rotation and looting (`Valimc.AI.settle/4`)
  and living rules (`Valimc.Entity.MobVitals`); the players push last. The
  result is a store step per mob: its position, its new body, its entity
  events and what its AI did beyond it (`effects`, with farmland it
  trampled, VMC-039a); a mob the kernel could not tick (near a chunk it
  cannot read) has none.
  """
  alias Valimc.AI
  alias Valimc.Data.Float32
  alias Valimc.Entity.{MobMotion, MobVitals, NativeMobs, Store}
  alias Valimc.Native
  alias Valimc.Physics.Kernel

  @doc """
  The steps of `mobs` (`[{id, entry}]`, in id order) over `view` and
  `border`, with the AI's `world` (`Valimc.AI.World`: its players push the
  mobs they touch): `{steps, world}`, the world as the mobs left it.
  """
  def steps(view, mobs, world, border, external \\ [])
  def steps(_view, [], world, _border, _external), do: {[], world}

  def steps(view, mobs, %AI.World{} = world, border, external) do
    external = collider_neighbors(mobs, external)
    {mobs, world, ctx} = AI.prepare(mobs, world)
    old = Map.new(mobs)
    ids = mobs |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
    index = Map.new(Enum.with_index(Tuple.to_list(ids)))

    # A player's standing box pushes the mobs it touches.
    players =
      for %{x: x, y: y, z: z} <- world.players,
          do: {{x, y, z}, {x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3}}

    # Mobs of a type without overrides share their travel attributes.
    {inputs, travel} =
      Enum.map_reduce(mobs, %{}, fn {_, entry}, travel -> input(entry, travel) end)

    # Other sections of the same group are stable while this section
    # ticks. Their fixed solid families join the grid without being ticked.
    {other_inputs, travel} =
      Enum.map_reduce(external, travel, fn {_, entry}, travel ->
        {input, travel} = input(entry, travel)

        {Map.merge(input, %{
           fixed: true,
           pushable: false,
           pushes: false,
           velocity: {0.0, 0.0, 0.0}
         }), travel}
      end)

    colliders =
      for {{_, entry}, i} <- Enum.with_index(mobs ++ external),
          box = collider_box(entry, :unsupported),
          box != :unsupported,
          do: {i, box}

    ticker = Kernel.mobs_begin(view, inputs ++ other_inputs, players, border, colliders)

    state = %{
      entries: Map.new(mobs),
      ids: ids,
      index: index,
      by_uuid: Map.new(mobs, fn {id, entry} -> {entry.entity.uuid, id} end),
      ctx: ctx,
      world: world,
      travel: travel,
      steps: [],
      pending: %{},
      solid: MapSet.new(colliders, &elem(&1, 0))
    }

    state =
      mobs
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{id, _}, i}, state -> step(view, ticker, old, id, i, state) end)

    velocities = ticker |> Kernel.mobs_finish() |> List.to_tuple()
    steps = Enum.reverse(state.steps)

    # The alerts later mobs left earlier ones; each mob's motion with every
    # push after it moved.
    steps =
      state.ctx
      |> AI.finish(
        Enum.map(steps, &{&1.id, &1.body}),
        Enum.map(steps, &{&1.id, old[&1.id]})
      )
      |> Enum.zip(steps)
      |> Enum.map(fn {{id, body}, step} ->
        %{step | body: %{body | velocity: elem(velocities, index[id])}}
      end)

    {steps, state.world}
  end

  @doc """
  The steps of a section whose mobs (`[{id, entry}]`, in id order) include
  native ones (VMC-081d), over a supplied view (oracle checks and tests):
  `native_tick/9` over `{:scene, ...}`, with a step for every mob as
  `steps/5` gives one. `env` is what the native turns read beyond the
  ticker (`%{region, level, players, items}`). A native mob's step body is
  its `NativeBody` row as it is after the tick.
  """
  def native_steps(view, mobs, world, border, external, native, env) do
    natives = for {id, entry} <- mobs, Store.native_entry?(entry), do: id

    source =
      {:scene, Valimc.Physics.Kernel.native(view, scene_region(mobs)), env.level, env.players,
       env.region}

    extra = %{items: Map.get(env, :items, []), only: natives}
    random = world.random
    elixir = Enum.reject(mobs, fn {_, entry} -> Store.native_entry?(entry) end)
    all = if elixir == [], do: [], else: mobs

    {steps, world, native_out} =
      native_tick(source, all, world, border, external, native, nil, :all, random, extra)

    _ = random

    changes =
      Map.new(native_out.changes, fn {id, _, events, effects, _} -> {id, {events, effects}} end)

    native_steps =
      for id <- natives do
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

    {Enum.sort_by(steps ++ native_steps, & &1.id), world}
  end

  # The cells a scene's mobs read: their boxes and moves, two blocks around.
  defp scene_region(mobs) do
    mobs
    |> Enum.map(fn {_, %{entity: e, body: body}} ->
      {width, height, _} = Valimc.Entity.Body.dimensions(body)
      half = width / 2 + 2.0
      {vx, vy, vz} = body.velocity

      {e.x - half + min(vx, 0), e.y - 2.0 + min(vy, 0), e.z - half + min(vz, 0),
       e.x + half + max(vx, 0), e.y + height + 2.0 + max(vy, 0), e.z + half + max(vz, 0)}
    end)
    |> Enum.reduce(fn {a0, b0, c0, d0, e0, f0}, {a1, b1, c1, d1, e1, f1} ->
      {min(a0, a1), min(b0, b1), min(c0, c1), max(d0, d1), max(e0, e1), max(f0, f1)}
    end)
  end

  @doc """
  One tick of a native section (VMC-081d, `NativeMobs.tick/8`): its native
  mobs take their turns in Rust over what it keeps resident (`source`
  `{:world, world}`, or an oracle's `{:scene, view, level, players,
  region}`), the section's Elixir mobs among them by yielding to their
  `MobTicks` turn here at their index, so every mob takes its turn in id
  order. `mobs` is every mob of the section that ticks (`[{id, entry}]`, in
  id order) when any is an Elixir mob, else `[]` (the native ones need no
  entry); `world` the Elixir AI's world (its `random` the section's level
  random); `external` the other sections' Elixir solids; `extra` the
  section's extras (`Native.mob_section_tick/7`).

  `{elixir_steps, world, %{moved, changes}}`: the Elixir mobs' steps as
  `steps/5` gives them, the world as they left it, and what changed of the
  native mobs (`Store.native_tick/3` takes it).
  """
  def native_tick(source, mobs, world, border, external, native, tick, mask, random, extra) do
    elixir = Enum.reject(mobs, fn {_, entry} -> Store.native_entry?(entry) end)

    if elixir == [] do
      units = Map.get(extra, :units, 16)

      {fixed, _} =
        Enum.map_reduce(List.wrap(external), %{}, fn {_, entry}, travel ->
          {input, travel} = input(entry, travel)
          {{:fixed, input, collider_box(entry, nil)}, travel}
        end)

      {:done, random, {[], moved, changes}} =
        NativeMobs.tick(native, source, tick, mask, random, fixed, extra, units)

      {[], %{world | random: random}, %{moved: moved, changes: changes}}
    else
      yield_tick(source, mobs, elixir, world, border, external, native, tick, mask, extra, random)
    end
  end

  defp yield_tick(
         source,
         mobs,
         elixir,
         world,
         border,
         external,
         native,
         tick,
         mask,
         extra,
         random
       ) do
    _ = border
    {mobs, world, ctx} = AI.prepare(mobs, world)
    old = Map.new(mobs)
    external = collider_neighbors(elixir, external)

    {entrants, travel} =
      Enum.map_reduce(elixir, %{}, fn {id, entry}, travel ->
        {input, travel} = input(entry, travel)
        {{id, input, collider_box(entry, nil)}, travel}
      end)

    {fixed, travel} =
      Enum.map_reduce(external, travel, fn {_, entry}, travel ->
        {input, travel} = input(entry, travel)
        {{:fixed, input, collider_box(entry, nil)}, travel}
      end)

    # What the native AI senses of the section's Elixir mobs.
    others = for {id, entry} <- elixir, do: {id, native_row(world, id, entry)}
    extra = Map.put(extra, :others, others)
    units = length(mobs) + length(fixed)

    case NativeMobs.tick(native, source, tick, mask, random, entrants ++ fixed, extra, units) do
      {:done, random, {velocities, moved, changes}} ->
        # (No Elixir mob took its turn: none was in the ticked chunks.)
        _ = velocities
        {[], %{world | random: random}, %{moved: moved, changes: changes}}

      {:yield, ticker, ids, i, random, moved, pushed} ->
        index = ids |> Tuple.to_list() |> Enum.with_index() |> Map.new()

        state = %{
          entries: Map.new(mobs),
          ids: ids,
          index: index,
          by_uuid: Map.new(mobs, fn {id, entry} -> {entry.entity.uuid, id} end),
          ctx: ctx,
          world: world,
          travel: travel,
          steps: [],
          pending: %{},
          solid: MapSet.new(for({id, _, box} <- entrants, box != nil, do: index[id])),
          native: native,
          ticker: ticker,
          natives:
            for({_, %{native: ref} = e} <- mobs, ref != nil, into: %{}, do: {e.entity.uuid, true})
        }

        state = native_moved(state, random, moved, pushed)
        {state, {velocities, moved, changes}} = run_native(old, i, state)
        velocities = Map.new(velocities)
        steps = Enum.reverse(state.steps)

        steps =
          ctx
          |> AI.finish(
            Enum.map(steps, &{&1.id, &1.body}),
            Enum.map(steps, &{&1.id, old[&1.id]})
          )
          |> Enum.zip(steps)
          |> Enum.map(fn {{id, body}, step} ->
            %{step | body: %{body | velocity: Map.fetch!(velocities, id)}}
          end)

        {steps, state.world, %{moved: moved, changes: changes}}
    end
  end

  # The Elixir mob at index `i` takes its turn, then the native turns go on
  # after it until the next Elixir mob's or the end.
  defp run_native(old, i, state) do
    id = elem(state.ids, i)
    state = step(nil, state.ticker, old, id, i, state)
    # The native AI senses it where its turn left it.
    resense = [native_row(state.world, id, state.entries[id])]

    case Native.dispatch(:mob_section_resume, segment(state, i + 1, 0), [
           state.native.ref,
           state.ticker,
           i + 1,
           state.world.random,
           resense
         ]) do
      {:yield, _, _, j, random, moved, pushed} ->
        run_native(old, j, native_moved(state, random, moved, pushed))

      {:done, random, out} ->
        {%{state | world: %{state.world | random: random}}, out}
    end
  end

  # An Elixir mob as the native AI senses it: the Elixir AI's row of it.
  defp native_row(world, id, %{entity: e} = entry) do
    case AI.World.entity(world, {:mob, e.uuid}) do
      nil -> AI.sensed({id, entry})
      row -> row
    end
    |> Map.take(
      ~w(uuid id type x y z yaw pitch eye width height box alive recent_mob_hurt baby huntable target in_love age in_water invulnerable killed_by panicking data)a
    )
  end

  # The native turns a run from index `i` takes before it yields.
  defp segment(state, i, n) do
    if i < tuple_size(state.ids) and Store.native_entry?(state.entries[elem(state.ids, i)]),
      do: segment(state, i + 1, n + 1),
      else: n
  end

  # The level random after the native turns, the Elixir mobs they pushed and
  # what the Elixir AI senses of the native mobs that moved.
  defp native_moved(state, random, moved, pushed) do
    entries =
      Enum.reduce(pushed, state.entries, fn {j, velocity}, entries ->
        other = elem(state.ids, j)
        e = entries[other]
        Map.put(entries, other, %{e | body: %{e.body | velocity: velocity}})
      end)

    {entries, world} =
      Enum.reduce(moved, {entries, %{state.world | random: random}}, fn
        {id, _, _, _, _}, {entries, world} when not is_map_key(entries, id) ->
          {entries, world}

        {id, {x, y, z}, yaw, pitch, alive}, {entries, world} ->
          e = entries[id]

          e = %{
            e
            | entity: %{e.entity | x: x, y: y, z: z},
              body: %{e.body | yaw: yaw, pitch: pitch, alive: alive}
          }

          world = if state.ctx, do: AI.resense_entry(world, id, e), else: world
          {Map.put(entries, id, e), world}
      end)

    %{state | entries: entries, world: world}
  end

  defp collider_neighbors(_mobs, []), do: []

  defp collider_neighbors(mobs, external) do
    own = MapSet.new(mobs, &elem(&1, 0))
    # No admitted move exceeds 64 per axis. Include a solid family's
    # extent and step-up before restricting the extra snapshot rows.
    {x0, y0, z0, x1, y1, z1} =
      mobs
      |> Enum.map(fn {_, %{entity: e, body: body}} ->
        Valimc.Entity.Body.box(body, {e.x, e.y, e.z})
      end)
      |> Enum.reduce(fn {a, b, c, d, e, f}, {g, h, i, j, k, l} ->
        {min(a, g), min(b, h), min(c, i), max(d, j), max(e, k), max(f, l)}
      end)

    reach = {x0 - 66, y0 - 66, z0 - 66, x1 + 66, y1 + 66, z1 + 66}

    external = if is_function(external, 1), do: external.(reach), else: external

    for {id, %{kind: :mob} = entry} <- external,
        not MapSet.member?(own, id),
        box = collider_box(entry, nil),
        box != nil,
        Valimc.Data.Box.intersects?(reach, box),
        do: {id, entry}
  end

  defp collider_box(%{entity: e, body: body}, default) do
    AI.Mobs.hook(body.type, :collider, [body, {e.x * 1.0, e.y * 1.0, e.z * 1.0}], default)
  end

  defp sync_collider(ticker, state, i, %{entity: e} = entry) do
    if MapSet.member?(state.solid, i),
      do: Kernel.mob_collider(ticker, i, {e.x, e.y, e.z}, collider_box(entry, nil))
  end

  defp input(%{entity: e, body: body}, travel) do
    key = {body.type, body.mob.attributes}

    {attributes, travel} =
      case travel do
        %{^key => attributes} ->
          {attributes, travel}

        _ ->
          attributes = MobMotion.travel(body.type, body.mob.attributes)
          {attributes, Map.put(travel, key, attributes)}
      end

    {MobMotion.kernel(body.type, {e.x * 1.0, e.y * 1.0, e.z * 1.0}, body, attributes), travel}
  end

  # One mob's turn, as vanilla's level ticks it: it thinks (seeing the mobs
  # before it where they moved to), travels and pushes in the ticker, then
  # finishes its tick. (The dragon is native, VMC-081d: its section runs its
  # actor.)
  defp step(view, ticker, old, id, i, state),
    do: ordinary_step(view, ticker, old, id, i, state)

  defp goal_position(ticker, i, entry, travel, self) do
    body = %{
      entry.body
      | mob: %{self.mob | ai: self.mind},
        data: self.data,
        yaw: self.yaw,
        pitch: self.pitch,
        head_yaw: self.head,
        velocity: self.velocity,
        on_ground: self.on_ground
    }

    entry = %{entry | body: body, entity: %{entry.entity | x: self.x, y: self.y, z: self.z}}
    {input, _} = input(entry, travel)
    Kernel.mob_goal_position(ticker, i, input)
  end

  defp ordinary_step(_view, ticker, old, id, i, state) do
    entry = sense_fluids(ticker, state.entries[id])
    # `baseTick`'s burning comes first (VMC-043b).
    {body, burnt} = MobVitals.base_tick(entry.body.type, entry.body)
    entry = %{entry | body: body}

    world = %{
      state.world
      | melee: &kills?(state, id, entry, &1, &2),
        goal_position: &goal_position(ticker, i, entry, state.travel, &1)
    }

    {{^id, body, {x, y, z}, effects}, ctx, world} =
      AI.think_mob(state.ctx, i, {id, entry}, world)

    world = %{world | melee: nil, goal_position: nil}

    entry = %{entry | body: body, entity: %{entry.entity | x: x, y: y, z: z}}
    state = %{state | ctx: ctx, world: world}
    {effects, state} = melee(ticker, id, entry, effects, state)
    {input, travel} = input(entry, state.travel)
    state = %{state | travel: travel}
    sync_collider(ticker, state, i, entry)
    {result, pushed} = Kernel.mob_step(ticker, i, input)

    # The mobs it pushed carry their new motion into their own turns.
    entries =
      Enum.reduce(pushed, state.entries, fn {j, velocity}, entries ->
        other = elem(state.ids, j)
        e = entries[other]
        Map.put(entries, other, %{e | body: %{e.body | velocity: velocity}})
      end)

    state = %{state | entries: entries}

    case result do
      {:ok, ticked} ->
        {made, rest} = split(effects)
        # A family that never falls (a bat's `checkFallDamage`) lands softly.
        ticked =
          if AI.Mobs.hook(entry.body.type, :falls?, [], true),
            do: ticked,
            else: %{ticked | landing: nil}

        {body, position} =
          MobMotion.apply(
            entry.body,
            ticked.mob,
            ticked.depths,
            ticked.powder_snow,
            ticked.eye_after,
            ticked.support
          )

        body = put_in(body.mob.motion.eye_water, ticked.eye_water)
        # The move's splash into water comes before the rest of its tick.
        {body, sounds} = AI.move_sounds(body, ticked.splash)

        # Turtle eggs it fell or stepped on may crack (level random).
        {cracked, world} = eggs(body, ticked, state.world)

        {body, position, settled, world} =
          AI.settle({id, old[id]}, body, position, world, %{
            swims: [ticked.pre_swim, ticked.swim],
            step: ticked.step
          })

        # A family that set its motion after the move (a squid's stroke)
        # tells the ticker, so later pushes add to it.
        if body.velocity != ticked.mob.velocity,
          do: Kernel.mob_velocity(ticker, i, body.velocity)

        {body, events} = MobVitals.apply(body.type, body, ticked)
        events = sounds ++ events
        # The sun on undead mobs and rain on burning ones (VMC-043b).
        {body, sunned} = Valimc.AI.Daylight.tick(body, position, world)
        # A family's own tick after the move (a zombie drowning, VMC-043b).
        {body, own} = AI.Mobs.after_move(body, position, ticked)
        {later, more} = split(settled ++ own)
        {crack_sounds, cracks} = split(cracked)
        {px, py, pz} = position
        entry = %{entry | body: body, entity: %{entry.entity | x: px, y: py, z: pz}}
        sync_collider(ticker, state, i, entry)
        {more, state} = lid_pushes(ticker, more, %{state | world: world})
        world = state.world

        step = %{
          id: id,
          revision: entry.revision,
          position: position,
          body: body,
          events:
            Map.get(state.pending, id, []) ++
              burnt ++ made ++ events ++ sunned ++ later ++ crack_sounds,
          effects: rest ++ more ++ trample(body, ticked) ++ cracks
        }

        step =
          case body.mob.ai do
            %AI.Mind{no_action: idle} -> Map.put(step, :idle, idle)
            _ -> step
          end

        %{
          state
          | entries: Map.put(state.entries, id, entry),
            world: AI.resense_entry(world, id, entry),
            steps: [step | state.steps]
        }

      _ ->
        state
    end
  end

  # The opening lid acts before the next entity ticks. Its displaced target
  # keeps its own turn, and an already-ticked target's returned step is amended.
  defp lid_pushes(ticker, effects, state) do
    Enum.map_reduce(effects, state, fn
      {:shulker_push, area, delta}, state ->
        state =
          Enum.reduce(state.entries, state, fn {id, _}, state ->
            entry = state.entries[id]

            cond do
              Store.native_entry?(entry) ->
                native_displace(state, id, entry, area, delta)

              Valimc.Entity.Displacement.meets?(entry, area) ->
                {input, travel} = input(entry, state.travel)

                case Kernel.mob_displace(ticker, state.index[id], input, delta) do
                  {:ok, result} ->
                    entry = Valimc.Entity.Displacement.apply(entry, result)
                    {x, y, z} = result |> elem(0)

                    steps =
                      Enum.map(state.steps, fn
                        %{id: ^id} = step -> %{step | body: entry.body, position: {x, y, z}}
                        step -> step
                      end)

                    %{
                      state
                      | entries: Map.put(state.entries, id, entry),
                        steps: steps,
                        travel: travel,
                        world: AI.resense_entry(state.world, id, entry)
                    }

                  _ ->
                    state
                end

              true ->
                state
            end
          end)

        # The owner forwards to all bodies outside this phase and its players.
        {{:shulker_push, area, delta, Map.keys(state.entries)}, state}

      effect, state ->
        {effect, state}
    end)
  end

  # Its melee hits on mobs of this tick land at once, as `doHurtTarget`
  # lands them mid-tick (VMC-043e: an axolotl's prey): the target ticks
  # (or ticked) hurt, its knockback in the ticker before any push; a hit on
  # a mob elsewhere stays an effect for the region.
  defp melee(ticker, id, entry, effects, state) do
    # The phase's membership and ticker positions stay fixed while bodies
    # move and are hurt. Reuse their indexes for every mob's effects.
    index = state.index
    by_uuid = state.by_uuid
    # The native mobs of this tick (VMC-081d) take their hits in their section.
    natives = Map.get(state, :natives, %{})

    Enum.flat_map_reduce(effects, state, fn
      {:attack, {:mob, uuid}} = effect, state
      when is_map_key(natives, uuid) ->
        target = by_uuid[uuid]
        target_entry = state.entries[target]
        store = %{entries: %{id => attacker(id, entry)}}

        case Valimc.Entity.Combat.mob_hit(store, id, target_entry.body.type) do
          {:ok, hit} ->
            hit = Map.merge(hit, extras(effects, uuid))
            {[], native_hit(state, target, target_entry, hit, nil)}

          _ ->
            {[effect], state}
        end

      {:attack, {:mob, uuid}} = effect, state when is_map_key(by_uuid, uuid) ->
        target = by_uuid[uuid]
        target_entry = state.entries[target]
        store = %{entries: %{id => attacker(id, entry)}}

        case Valimc.Entity.Combat.mob_hit(store, id, target_entry.body.type) do
          {:ok, hit} ->
            # What its family adds to the hit (an iron golem's, VMC-044a2).
            hit = Map.merge(hit, extras(effects, uuid))

            {body, events, hurt} =
              Valimc.Entity.Combat.hit_body(target_entry.body, target_entry.entity, hit)

            # One still to tick runs its hurt and death timers this tick
            # (`baseTick`), as the owner's ageing ran them for the rest.
            body =
              if hurt and not Enum.any?(state.steps, &(&1.id == target)),
                do: timers(body),
                else: body

            Kernel.mob_velocity(ticker, index[target], body.velocity)
            {[], hurt(state, ticker, target, %{target_entry | body: body}, events)}

          _ ->
            {[effect], state}
        end

      effect, state ->
        {[effect], state}
    end)
  end

  # Whether mob `id`'s melee hit on `ref` kills it, for the rest of its think.
  defp kills?(state, id, entry, {:mob, uuid} = ref, effects) do
    if Map.has_key?(Map.get(state, :natives, %{}), uuid),
      do: native_kills?(state, id, entry, uuid, effects),
      else: elixir_kills?(state, id, entry, ref, effects)
  end

  defp native_kills?(state, id, entry, uuid, effects) do
    target_id = state.by_uuid[uuid]
    target = state.entries[target_id]

    case Valimc.Entity.Combat.mob_hit(
           %{entries: %{id => attacker(id, entry)}},
           id,
           target.body.type
         ) do
      {:ok, hit} ->
        hit = Map.merge(hit, extras(effects, uuid))
        Native.mob_section_kills(state.native.ref, target_id, hit)

      _ ->
        false
    end
  end

  defp elixir_kills?(state, id, entry, {:mob, uuid}, effects) do
    with target_id when target_id != nil <- state.by_uuid[uuid],
         target = state.entries[target_id],
         {:ok, hit} <-
           Valimc.Entity.Combat.mob_hit(
             %{entries: %{id => attacker(id, entry)}},
             id,
             target.body.type
           ),
         hit = Map.merge(hit, extras(effects, uuid)),
         {body, _, true} <- Valimc.Entity.Combat.hit_body(target.body, target.entity, hit) do
      not Valimc.Entity.Mob.alive?(body.mob)
    else
      _ -> false
    end
  end

  # The attacker as a store entry (`Combat.mob_hit/3`).
  defp attacker(id, entry),
    do: %{Map.put(entry, :kind, :mob) | entity: Map.put_new(entry.entity, :entity_id, id)}

  defp extras(effects, uuid) do
    Enum.find_value(effects, %{}, fn
      {:attack_extra, {:mob, ^uuid}, extras} -> extras
      _ -> nil
    end)
  end

  # A hit (and push) on a native mob mid-tick: its section applies it,
  # with the ticker's motion, its hurt timers when it still has its turn and
  # the events joining its turn's.
  defp native_hit(state, target, entry, hit, push) do
    case Native.mob_section_hit(state.native.ref, state.ticker, target, hit, push) do
      {:ok, {_, _, {{x, y, z}, row}}} ->
        entry = %{
          entry
          | entity: %{entry.entity | x: x, y: y, z: z},
            body: NativeMobs.merge(row, entry.body)
        }

        %{
          state
          | entries: Map.put(state.entries, target, entry),
            world: AI.resense_entry(state.world, target, entry)
        }

      _ ->
        state
    end
  end

  defp native_displace(state, id, entry, area, delta) do
    if Valimc.Entity.Displacement.meets?(entry, area) do
      case Native.mob_section_displace(state.native.ref, state.ticker, id, delta) do
        {:ok, {_, _, {{x, y, z}, row}}} ->
          entry = %{
            entry
            | entity: %{entry.entity | x: x, y: y, z: z},
              body: NativeMobs.merge(row, entry.body)
          }

          %{
            state
            | entries: Map.put(state.entries, id, entry),
              world: AI.resense_entry(state.world, id, entry)
          }

        _ ->
          state
      end
    else
      state
    end
  end

  defp timers(%{mob: mob} = body) do
    health = Valimc.Living.Health.tick(mob.living.health)
    %{body | mob: %{mob | living: %{mob.living | health: health}}}
  end

  # A hurt mob's entry, and its step if it already ticked (with the hit's
  # entity events), as others sense it.
  defp hurt(state, ticker, id, entry, events) do
    sync_collider(ticker, state, state.index[id], entry)

    {steps, stepped} =
      Enum.map_reduce(state.steps, false, fn
        %{id: ^id} = step, _ -> {%{step | body: entry.body, events: step.events ++ events}, true}
        step, stepped -> {step, stepped}
      end)

    pending =
      if stepped, do: state.pending, else: Map.update(state.pending, id, events, &(&1 ++ events))

    %{
      state
      | entries: Map.put(state.entries, id, entry),
        steps: steps,
        pending: pending,
        world: AI.resense_entry(state.world, id, entry)
    }
  end

  # Entity.baseTick refreshes fluid observations before every AI turn. A
  # water move may retain its old flag until this refresh, including on exit.
  defp sense_fluids(ticker, %{body: %{mob: %Valimc.Entity.Mob{} = mob} = body} = entry) do
    {_, _, eye} = Valimc.Entity.Body.dimensions(body)
    e = entry.entity

    with {:ok, {water, lava, eye}} <-
           Kernel.mob_sense(ticker, box(entry), {e.x * 1.0, e.y + eye, e.z * 1.0}) do
      motion = %{mob.motion | water: water * 1.0, lava: lava * 1.0, eye: eye}
      %{entry | body: %{body | mob: %{mob | motion: motion}}}
    else
      _ -> entry
    end
  end

  defp sense_fluids(_ticker, entry), do: entry

  defp box(%{entity: e, body: body}) do
    {width, height, _} = Valimc.Entity.Body.dimensions(body)
    half = width / 2.0
    {e.x - half, e.y * 1.0, e.z - half, e.x + half, e.y + height, e.z + half}
  end

  # Farmland the mob landed on gives way (VMC-039a, `FarmlandBlock.fallOn`);
  # the owner applies it while mob griefing is on.
  defp trample(body, %{landing: {state, distance}, landing_pos: cell}) when cell != nil do
    {w, h, _} = Valimc.Entity.Body.dimensions(body)
    roll = (:rand.uniform(16_777_216) - 1) / 16_777_216

    if Valimc.Blocks.Farmland.tramples?(state, distance, {w, h}, roll),
      do: [{:trample, cell}],
      else: []
  end

  defp trample(_body, _ticked), do: []

  @turtle_egg Valimc.Data.Blocks.id("turtle_egg")
  # `Zombie.class` and its kinds never crack eggs falling (`fallOn`).
  @zombies ~w(minecraft:zombie minecraft:husk minecraft:drowned minecraft:zombie_villager minecraft:zombified_piglin)

  # `TurtleEggBlock.fallOn` (one in three, not a zombie) and `stepOn` (one
  # in a hundred on the ground) for a mob that may break eggs (not a turtle
  # or bat, while mobs may grief), from the level's random: `{:crack_egg,
  # cell, state}` effects and their sounds, pitched from it too.
  defp eggs(%{type: type}, ticked, world)
       when type not in ["minecraft:turtle", "minecraft:bat"] do
    if world.mob_griefing do
      {fall, world} =
        case ticked do
          %{landing: {state, _}, landing_pos: cell} when cell != nil and type not in @zombies ->
            crack(world, cell, state, 3)

          _ ->
            {[], world}
        end

      {step, world} =
        case ticked do
          %{on_block: {cell, state}} -> crack(world, cell, state, 100)
          _ -> {[], world}
        end

      {fall ++ step, world}
    else
      {[], world}
    end
  end

  defp eggs(_body, _ticked, world), do: {[], world}

  defp crack(world, cell, state, chance) do
    if Valimc.Data.Blocks.block_id(state) == @turtle_egg do
      {n, random} = AI.Random.int(world.random, chance)

      if n == 0 do
        {f, random} = AI.Random.float(random)
        pitch = Float32.round(Float32.round(0.9) + Float32.round(f * Float32.round(0.2)))
        {cx, cy, cz} = cell
        id = AI.Facts.sound_id("minecraft:entity.turtle.egg_break")

        sound =
          {:sound_at, id, "blocks", {cx + 0.5, cy + 0.5, cz + 0.5}, Float32.round(0.7), pitch}

        {[{:crack_egg, cell, state}, sound], %{world | random: random}}
      else
        {[], %{world | random: random}}
      end
    else
      {[], world}
    end
  end

  # Sounds, entity events and swings are the mob's events; the rest leaves it.
  defp split(effects) do
    {events, rest} =
      Enum.split_with(effects, fn
        {:sound, _, _, _, _, _} -> true
        {:sound_at, _, _, _, _, _} -> true
        {:sound_block, _, _, _, _, _} -> true
        {:damage, _} -> true
        {:damage, _, _, _, _} -> true
        {:event, _} -> true
        {:particles, _, _, _, _, _} -> true
        :swing -> true
        {:swing, _} -> true
        _ -> false
      end)

    {Enum.map(events, fn
       :swing -> {:swing, :main_hand}
       e -> e
     end), rest}
  end
end
