defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of an owner's mobs (VMC-015i), one mob at a time in id order as
  vanilla's level ticks them, so each thinks with the mobs before it where
  they moved to (VMC-043e): its AI (`Valimc.AI.think_mob/4`, VMC-041a), its
  travel in the physics kernel (`Valimc.Physics.Kernel.mobs/4`: the move
  and jump controls, travel, collision, fluids, climbing, slowing blocks),
  its pushes (by the players it touches, and of the mobs it touches, which
  push it back), then its body rotation and looting (`Valimc.AI.settle/5`)
  and living rules (`Valimc.Entity.MobVitals`); the players push last. The
  result is a store step per mob: its position, its new body, its entity
  events and what its AI did beyond it (`effects`, with farmland it
  trampled, VMC-039a); a mob the kernel could not tick (near a chunk it
  cannot read) has none.
  """
  alias Valimc.AI
  alias Valimc.Entity.{MobMotion, MobVitals}
  alias Valimc.Physics.Kernel

  @doc """
  The steps of `mobs` (`[{id, entry}]`, in id order) over `view` and
  `border`, with the AI's `world` (`Valimc.AI.World`: its players push the
  mobs they touch): `{steps, world}`, the world as the mobs left it.
  """
  def steps(_view, [], world, _border), do: {[], world}

  def steps(view, mobs, %AI.World{} = world, border) do
    {mobs, world, ctx} = AI.prepare(mobs, world)
    old = Map.new(mobs)
    ids = mobs |> Enum.map(&elem(&1, 0)) |> List.to_tuple()

    # A player's standing box pushes the mobs it touches.
    players =
      for %{x: x, y: y, z: z} <- world.players,
          do: {{x, y, z}, {x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3}}

    # Mobs of a type without overrides share their travel attributes.
    {inputs, travel} =
      Enum.map_reduce(mobs, %{}, fn {_, entry}, travel -> input(entry, travel) end)

    ticker = Kernel.mobs_begin(view, inputs, players, border)

    state = %{
      entries: Map.new(mobs),
      ids: ids,
      ctx: ctx,
      world: world,
      travel: travel,
      steps: [],
      pending: %{}
    }

    state =
      mobs
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{id, _}, i}, state -> step(view, ticker, old, id, i, state) end)

    velocities = ticker |> Kernel.mobs_finish() |> List.to_tuple()
    position = Map.new(Enum.with_index(Tuple.to_list(ids)))
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
        %{step | body: %{body | velocity: elem(velocities, position[id])}}
      end)

    {steps, state.world}
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
  # finishes its tick.
  defp step(view, ticker, old, id, i, state) do
    entry = first_fluids(view, state.entries[id])
    # `baseTick`'s burning comes first (VMC-043b).
    {body, burnt} = MobVitals.base_tick(entry.body.type, entry.body)
    entry = %{entry | body: body}

    world = %{state.world | melee: &kills?(state, id, entry, &1, &2)}

    {{^id, body, {x, y, z}, effects}, ctx, world} =
      AI.think_mob(state.ctx, i, {id, entry}, world)

    world = %{world | melee: nil}

    entry = %{entry | body: body, entity: %{entry.entity | x: x, y: y, z: z}}
    state = %{state | ctx: ctx, world: world}
    {effects, state} = melee(ticker, id, entry, effects, state)
    {input, travel} = input(entry, state.travel)
    state = %{state | travel: travel}
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

        {body, position, settled, world} =
          AI.settle({id, old[id]}, body, position, state.world, %{
            swims: [ticked.pre_swim, ticked.swim],
            step: ticked.step
          })

        # A family that set its motion after the move (a squid's stroke)
        # tells the ticker, so later pushes add to it.
        if body.velocity != ticked.mob.velocity,
          do: Kernel.mob_velocity(ticker, i, body.velocity)

        {body, events} = MobVitals.apply(body.type, body, ticked)
        # The sun on undead mobs and rain on burning ones (VMC-043b).
        {body, sunned} = Valimc.AI.Daylight.tick(body, position, world)
        # A family's own tick after the move (a zombie drowning, VMC-043b).
        {body, own} = AI.Mobs.after_move(body, position, ticked)
        {later, more} = split(settled ++ own)
        {px, py, pz} = position
        entry = %{entry | body: body, entity: %{entry.entity | x: px, y: py, z: pz}}

        step = %{
          id: id,
          revision: entry.revision,
          position: position,
          body: body,
          events: Map.get(state.pending, id, []) ++ burnt ++ made ++ events ++ sunned ++ later,
          effects: rest ++ more ++ trample(body, ticked) ++ crush_eggs(body.type, ticked, world)
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

  # Its melee hits on mobs of this tick land at once, as `doHurtTarget`
  # lands them mid-tick (VMC-043e: an axolotl's prey): the target ticks
  # (or ticked) hurt, its knockback in the ticker before any push; a hit on
  # a mob elsewhere stays an effect for the region.
  defp melee(ticker, id, entry, effects, state) do
    index = state.ids |> Tuple.to_list() |> Enum.with_index() |> Map.new()
    by_uuid = Map.new(state.entries, fn {other, e} -> {e.entity.uuid, other} end)

    Enum.flat_map_reduce(effects, state, fn
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
            {[], hurt(state, target, %{target_entry | body: body}, events)}

          _ ->
            {[effect], state}
        end

      effect, state ->
        {[effect], state}
    end)
  end

  # Whether mob `id`'s melee hit on `ref` kills it, for the rest of its think.
  defp kills?(state, id, entry, {:mob, uuid}, effects) do
    with {_, target} <- Enum.find(state.entries, fn {_, e} -> e.entity.uuid == uuid end),
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

  defp timers(%{mob: mob} = body) do
    health = Valimc.Living.Health.tick(mob.living.health)
    %{body | mob: %{mob | living: %{mob.living | health: health}}}
  end

  # A hurt mob's entry, and its step if it already ticked (with the hit's
  # entity events), as others sense it.
  defp hurt(state, id, entry, events) do
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

  # A mob's first tick reads the fluids it stands in and its eyes', as its
  # base tick would before its AI (later ticks read what its last move left).
  defp first_fluids(view, %{body: %{mob: %Valimc.Entity.Mob{ai: ai} = mob} = body} = entry) do
    if match?(%AI.Mind{tick: tick} when tick > 0, ai) do
      entry
    else
      {_, _, eye} = Valimc.Entity.Body.dimensions(body)
      e = entry.entity

      with {:ok, %{water: water, lava: lava}} <- Kernel.fluids(view, box(entry)),
           {:ok, eye} <- Kernel.eye_block(view, box(entry), {e.x * 1.0, e.y + eye, e.z * 1.0}) do
        motion = %{mob.motion | water: water * 1.0, lava: lava * 1.0, eye: eye}
        %{entry | body: %{body | mob: %{mob | motion: motion}}}
      else
        _ -> entry
      end
    end
  end

  defp first_fluids(_view, entry), do: entry

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

  @turtle_eggs MapSet.new(Valimc.Data.Blocks.states("turtle_egg"))
  @zombies ~w(minecraft:zombie minecraft:husk minecraft:drowned minecraft:zombie_villager
              minecraft:zombified_piglin)

  # `TurtleEggBlock.fallOn` (one in three, not by a zombie) and `stepOn` (one
  # in a hundred) of the eggs a mob landed or stands on (VMC-043e): turtles
  # and bats never crush them, others while mob griefing is on.
  defp crush_eggs(type, _ticked, %{mob_griefing: false}) when is_binary(type), do: []

  defp crush_eggs(type, _ticked, _world) when type in ["minecraft:turtle", "minecraft:bat"],
    do: []

  defp crush_eggs(type, ticked, _world) do
    fall =
      case ticked do
        %{landing: {state, _}, landing_pos: cell} when cell != nil ->
          if MapSet.member?(@turtle_eggs, state) and type not in @zombies,
            do: [{:crush_egg, cell, 3}],
            else: []

        _ ->
          []
      end

    step =
      case ticked do
        %{on_block: {cell, state}} ->
          if MapSet.member?(@turtle_eggs, state), do: [{:crush_egg, cell, 100}], else: []

        _ ->
          []
      end

    fall ++ step
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
