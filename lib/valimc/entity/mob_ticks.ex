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
      steps: []
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

    {{^id, body, {x, y, z}, effects}, ctx, world} =
      AI.think_mob(state.ctx, i, {id, entry}, state.world)

    entry = %{entry | body: body, entity: %{entry.entity | x: x, y: y, z: z}}
    {input, travel} = input(entry, state.travel)
    state = %{state | ctx: ctx, world: world, travel: travel}
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
          MobMotion.apply(entry.body, ticked.mob, ticked.depths, ticked.powder_snow)

        body = put_in(body.mob.motion.eye_water, ticked.eye_water)

        {body, position, settled, world} =
          AI.settle({id, old[id]}, body, position, state.world, ticked.swim)

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
          events: burnt ++ made ++ events ++ sunned ++ later,
          effects: rest ++ more ++ trample(body, ticked)
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

  # A mob's first tick reads the fluids it stands in, as its base tick
  # would before its AI (later ticks read what its last move left).
  defp first_fluids(view, %{body: %{mob: %Valimc.Entity.Mob{ai: ai} = mob} = body} = entry) do
    if match?(%AI.Mind{tick: tick} when tick > 0, ai) do
      entry
    else
      case Kernel.fluids(view, box(entry)) do
        {:ok, %{water: water, lava: lava}} ->
          motion = %{mob.motion | water: water * 1.0, lava: lava * 1.0}
          %{entry | body: %{body | mob: %{mob | motion: motion}}}

        _ ->
          entry
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

  # Sounds, entity events and swings are the mob's events; the rest leaves it.
  defp split(effects) do
    {events, rest} =
      Enum.split_with(effects, fn
        {:sound, _, _, _, _, _} -> true
        {:sound_at, _, _, _, _, _} -> true
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
