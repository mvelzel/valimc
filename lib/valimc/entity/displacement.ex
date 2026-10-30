defmodule Valimc.Entity.Displacement do
  @moduledoc "External lid moves over owned entity entries, without consuming their own tick."
  alias Valimc.Data.Box
  alias Valimc.Entity.{Body, Mob}

  @doc "Whether an entry is met by a lid's swept slab and admits its external move."
  def meets?(%{body: %Body{type: "minecraft:shulker"}}, _area), do: false
  def meets?(%{body: %Body{type: "minecraft:ender_dragon"}}, _area), do: false

  def meets?(%{body: %Body{type: type}}, _area)
      when type in ["minecraft:area_effect_cloud", "minecraft:shulker_bullet"], do: false

  def meets?(entry, area) do
    case input(entry) do
      {_, _, _, _, _} -> Box.intersects?(area, box(entry))
      _ -> false
    end
  end

  @doc "The external mover's box, preserving current age and family dimensions."
  def box(%{entity: e, body: %Body{} = body}), do: Body.box(body, {e.x, e.y, e.z})

  def box(%{entity: e, body: %Valimc.Entity.NativeBody{} = row}),
    do: Valimc.Entity.NativeBody.box(row, {e.x, e.y, e.z})

  def box(entry) do
    {{x, y, z}, {w, h}, _, _, _} = input(entry)
    {x - w, y, z - w, x + w, y + h, z + w}
  end

  @doc "An entry's kernel body, or nil for types with no movable body."
  def input(%{kind: kind, entity: e, motion: motion}) when kind in [:item, :orb] do
    {half, height, gravity} = if kind == :item, do: {0.125, 0.25, 0.04}, else: {0.25, 0.5, 0.03}
    gravity = if motion.no_gravity, do: 0.0, else: gravity

    {{e.x * 1.0, e.y * 1.0, e.z * 1.0}, {half, height}, motion.velocity,
     {motion.on_ground, 0.0, true, false}, {0.0, false, false, gravity, 0.98}}
  end

  def input(%{kind: kind, entity: e, body: %Body{} = body}) when kind in [:mob, :object] do
    {width, height, _} = Body.dimensions(body)
    living = body.mob != nil
    step = if living, do: Mob.value(body.type, body.mob, "minecraft:step_height"), else: 0.0
    gravity = if living, do: Mob.value(body.type, body.mob, "minecraft:gravity"), else: 0.04
    gravity = if body.no_gravity, do: 0.0, else: gravity

    {{e.x * 1.0, e.y * 1.0, e.z * 1.0}, {width / 2, height}, body.velocity,
     {body.on_ground, step * 1.0, true, false}, {0.0, false, living, gravity * 1.0, 0.98}}
  end

  # A native mob (VMC-081d) from its row.
  def input(%{kind: :mob, entity: e, body: %Valimc.Entity.NativeBody{} = row}) do
    {width, height, _} = row.dimensions
    gravity = if row.no_gravity, do: 0.0, else: row.gravity

    {{e.x * 1.0, e.y * 1.0, e.z * 1.0}, {width / 2, height}, row.velocity,
     {row.on_ground, row.step_height * 1.0, true, false}, {0.0, false, true, gravity * 1.0, 0.98}}
  end

  def input(_), do: nil

  @doc "Bounded live solid-family boxes around an external move, from the same owner's entries."
  def colliders(entries, entry, {dx, dy, dz}) do
    {x0, y0, z0, x1, y1, z1} = box(entry)
    {_, _, _, {_, step, _, _}, _} = input(entry)
    halo = 0.01 + step

    query =
      {x0 + min(dx, 0) - halo, y0 + min(dy, 0) - halo, z0 + min(dz, 0) - halo,
       x1 + max(dx, 0) + halo, y1 + max(dy, 0) + halo, z1 + max(dz, 0) + halo}

    Enum.reduce_while(entries, {:ok, []}, fn
      {_, %{body: %Body{} = body, entity: e}}, {:ok, found} ->
        collider = Valimc.AI.Mobs.hook(body.type, :collider, [body, {e.x, e.y, e.z}], nil)

        found =
          if collider && Box.intersects?(collider, query), do: [collider | found], else: found

        if length(found) > 256,
          do: {:halt, {:error, :entity_query_limit}},
          else: {:cont, {:ok, found}}

      _, acc ->
        {:cont, acc}
    end)
  end

  @doc "An entry after a successful external move; revisions remain the store's responsibility."
  def apply(entry, {{x, y, z}, velocity, on_ground}) do
    entry = %{entry | entity: %{entry.entity | x: x, y: y, z: z}}

    if entry.kind in [:item, :orb],
      do: %{entry | motion: %{entry.motion | velocity: velocity, on_ground: on_ground}},
      else: %{entry | body: %{entry.body | velocity: velocity, on_ground: on_ground}}
  end
end
