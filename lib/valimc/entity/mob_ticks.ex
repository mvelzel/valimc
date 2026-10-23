defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of an owner's mobs (VMC-015i): every mob of the section in one
  physics-kernel call (`Valimc.Physics.Kernel.mobs/4`: travel, collision,
  fluids, climbing, slowing blocks and pushing, by mobs and by `players`),
  then each mob's living rules (`Valimc.Entity.MobVitals`). The result is a
  store step per mob: its position, its new body and its entity events; a
  mob the kernel could not tick (near a chunk it cannot read) has none.
  """
  alias Valimc.Entity.{MobMotion, MobVitals}
  alias Valimc.Physics.Kernel

  @doc """
  The steps of `mobs` (`[{id, entry}]`) over `view` and `border`, pushed by
  `players` (`{feet, aim}`, as orbs follow them).
  """
  def steps(_view, [], _players, _border), do: []

  def steps(view, mobs, players, border) do
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
      for {{x, y, z}, _aim} <- players,
          do:
            {{x * 1.0, y * 1.0, z * 1.0}, {x - 0.3, y * 1.0, z - 0.3, x + 0.3, y + 1.8, z + 0.3}}

    {:ok, results} = Kernel.mobs(view, inputs, players, border)

    for {{id, entry}, {:ok, ticked}} <- Enum.zip(mobs, results) do
      {body, position} = MobMotion.apply(entry.body, ticked.mob)
      {body, events} = MobVitals.apply(body.type, body, ticked)
      %{id: id, revision: entry.revision, position: position, body: body, events: events}
    end
  end
end
