defmodule Valimc.World.BlockBodies do
  @moduledoc """
  The ticks of block-like bodies a region owner runs in its items phase
  (VMC-050a): a primed TNT moves through the physics kernel
  (`Physics.Kernel.block_bodies/3`) and burns its fuse, and explodes once it
  runs out (`PrimedTnt.tick`). A body the kernel cannot step (a cell it
  cannot read, past its bounds) stays where it is; its fuse burns anyway.
  """
  alias Valimc.Entity.Body
  alias Valimc.Physics.Kernel

  @types ["minecraft:tnt"]

  @doc "Whether bodies of `type` tick here."
  def ticks?(type), do: type in @types

  @doc """
  One tick of `bodies` (`[{id, entry}]`): `[{:moved, id, revision, position,
  body}]` for each body still burning and `{:explode, id, revision,
  position}` for each whose fuse ran out.
  """
  def tick([], _border), do: []

  def tick(bodies, border) do
    inputs =
      Enum.map(bodies, fn {_, %{entity: e, body: body}} ->
        {{e.x * 1.0, e.y * 1.0, e.z * 1.0}, body.velocity, body.on_ground, body.no_gravity, :tnt}
      end)

    {:ok, results} = Kernel.block_bodies(Valimc.World.View.new(), inputs, border)

    Enum.zip_with(bodies, results, fn {id, %{entity: e, body: body, revision: revision}},
                                      result ->
      {position, body} =
        case result do
          {:ok, position, velocity, on_ground, _moved_y} ->
            {position, %{body | velocity: velocity, on_ground: on_ground}}

          _ ->
            {{e.x, e.y, e.z}, body}
        end

      fuse = body.data.fuse - 1

      if fuse <= 0,
        do: {:explode, id, revision, position},
        else: {:moved, id, revision, position, put_fuse(body, fuse)}
    end)
  end

  defp put_fuse(%Body{data: data} = body, fuse), do: %{body | data: %{data | fuse: fuse}}
end
