defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of an owner's mobs (VMC-015i): their AI (`Valimc.AI.think/2`,
  VMC-041a), then every mob of the section in one physics-kernel call
  (`Valimc.Physics.Kernel.mobs/4`: the move and jump controls, travel,
  collision, fluids, climbing, slowing blocks and pushing, by mobs and by
  the players), then each mob's body rotation (`Valimc.AI.settle/3`) and
  living rules (`Valimc.Entity.MobVitals`). The result is a store step per
  mob: its position, its new body, its entity events and what its AI did
  beyond it (`effects`); a mob the kernel could not tick (near a chunk it
  cannot read) has none.
  """
  alias Valimc.AI
  alias Valimc.Entity.{MobMotion, MobVitals}
  alias Valimc.Physics.Kernel

  @doc """
  The steps of `mobs` (`[{id, entry}]`, in id order) over `view` and
  `border`, with the AI's `world` (`Valimc.AI.World`: its players push the
  mobs they touch).
  """
  def steps(_view, [], _world, _border), do: []

  def steps(view, mobs, %AI.World{} = world, border) do
    thought = AI.think(mobs, world)

    {mobs, effects} =
      Enum.zip_with(mobs, thought, fn {id, entry}, {id, body, effects} ->
        events = for {:sound, _, _, _, _, _} = e <- effects, do: e
        swings = for :swing <- effects, do: {:swing, :main_hand}
        {{id, %{entry | body: body}}, {id, events ++ swings, effects -- (events -- [:swing])}}
      end)
      |> Enum.unzip()

    effects = Map.new(effects, fn {id, events, rest} -> {id, {events, rest}} end)
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

    for {{id, entry}, {:ok, ticked}} <- Enum.zip(mobs, results) do
      {body, {x, _, z} = position} = MobMotion.apply(entry.body, ticked.mob, ticked.depths)
      body = AI.settle(body, {x, z}, {entry.entity.x, entry.entity.z})
      {body, events} = MobVitals.apply(body.type, body, ticked)
      {made, rest} = effects[id]

      step = %{
        id: id,
        revision: entry.revision,
        position: position,
        body: body,
        events: made ++ events,
        effects: rest
      }

      case body.mob.ai do
        %AI.Mind{no_action: idle} -> Map.put(step, :idle, idle)
        _ -> step
      end
    end
  end
end
