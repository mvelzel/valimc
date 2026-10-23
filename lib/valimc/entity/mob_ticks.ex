defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of an owner's mobs (VMC-015i): their AI (`Valimc.AI.think/2`,
  VMC-041a), then every mob of the section in one physics-kernel call
  (`Valimc.Physics.Kernel.mobs/4`: the move and jump controls, travel,
  collision, fluids, climbing, slowing blocks and pushing, by mobs and by
  the players), then each mob's body rotation and looting
  (`Valimc.AI.settle/4`) and living rules (`Valimc.Entity.MobVitals`). The
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
    # `baseTick`'s burning comes first (VMC-043b).
    {mobs, burnt} =
      Enum.map_reduce(mobs, %{}, fn {id, entry}, acc ->
        case MobVitals.base_tick(entry.body.type, entry.body) do
          {_, []} = {body, _} -> {{id, %{entry | body: body}}, acc}
          {body, events} -> {{id, %{entry | body: body}}, Map.put(acc, id, events)}
        end
      end)

    {thought, world} = AI.think(mobs, world)
    old = Map.new(mobs)

    {mobs, effects} =
      Enum.zip_with(mobs, thought, fn {id, entry}, {id, body, {x, y, z}, effects} ->
        entity = %{entry.entity | x: x, y: y, z: z}
        {made, rest} = split(effects)

        {{id, %{entry | body: body, entity: entity}},
         {id, {Map.get(burnt, id, []) ++ made, rest}}}
      end)
      |> Enum.unzip()

    effects = Map.new(effects)
    # Mobs of a type without overrides share their travel attributes.
    {inputs, _} =
      Enum.map_reduce(mobs, %{}, fn {_, %{entity: e, body: body}}, cache ->
        key = {body.type, body.mob.attributes}

        {attributes, cache} =
          case cache do
            %{^key => attributes} ->
              {attributes, cache}

            _ ->
              then(
                MobMotion.travel(body.type, body.mob.attributes),
                &{&1, Map.put(cache, key, &1)}
              )
          end

        {MobMotion.kernel(body.type, {e.x * 1.0, e.y * 1.0, e.z * 1.0}, body, attributes), cache}
      end)

    # A player's standing box pushes the mobs it touches.
    players =
      for %{x: x, y: y, z: z} <- world.players,
          do: {{x, y, z}, {x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3}}

    {:ok, results} = Kernel.mobs(view, inputs, players, border)

    {steps, world} =
      Enum.zip(mobs, results)
      |> Enum.flat_map_reduce(world, fn
        {{id, entry}, {:ok, ticked}}, world ->
          {body, position} =
            MobMotion.apply(entry.body, ticked.mob, ticked.depths, ticked.powder_snow)

          {body, position, settled, world} =
            AI.settle({id, old[id]}, body, position, world)

          {body, events} = MobVitals.apply(body.type, body, ticked)
          # The sun on undead mobs and rain on burning ones (VMC-043b).
          {body, sunned} = Valimc.AI.Daylight.tick(body, position, world)
          events = events ++ sunned
          # A family's own tick after the move (a zombie drowning, VMC-043b).
          {body, own} = AI.Mobs.after_move(body, position, ticked)
          {made, rest} = effects[id]
          {later, more} = split(settled ++ own)

          step = %{
            id: id,
            revision: entry.revision,
            position: position,
            body: body,
            events: made ++ events ++ later,
            effects: rest ++ more ++ trample(body, ticked)
          }

          step =
            case body.mob.ai do
              %AI.Mind{no_action: idle} -> Map.put(step, :idle, idle)
              _ -> step
            end

          {[step], world}

        _, world ->
          {[], world}
      end)

    {steps, world}
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
        {:event, _} -> true
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
