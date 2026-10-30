defmodule Valimc.Entity.Leashes do
  @moduledoc """
  What players do with leads (VMC-043c3), for the owner of the bodies:

  - a fence's use (`LeadItem.bindPlayerMobs`, `bind/3`): the player's mobs
    around it move to the fence's knot, made where none is;
  - a fence knot's (`LeashFenceKnotEntity.interact`, `knot/3`): the player's
    mobs move to it, else (not sneaking) its mobs move to the player;
    shears snip its leads.

  `request` is the player's interaction with the player's body as a holder
  (`holder: %{id, x, y, z, width, height}`) and whether it sneaks. Mobs are
  `{id, row, {x, y, z}}`, their rows' leads as their sections show them
  (VMC-081d: a mob's own lead part is its section's, `kinds::leads`; the
  owner applies `attach/3` and `drop/1` of a row through its section). A
  lead's holder is `{:player, uuid}` or `{:knot, pos}`.
  """
  alias Valimc.Data.Float32
  alias Valimc.Entity.{Body, Mob, NativeBody}
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @lead ItemTypes.id("minecraft:lead")
  @shears ItemTypes.id("minecraft:shears")
  # `leashableInArea`: a 32-block box around the centre.
  @area 16.0

  @doc """
  What an interaction did (`interacted`'s outcome): `fields` over keeping
  the hand, no swing, no events, others, drops, conversion, discard or
  freed knots.
  """
  def outcome(fields),
    do:
      Map.merge(
        %{
          hand: :keep,
          swing: false,
          events: [],
          others: nil,
          drops: [],
          convert: nil,
          discard: false,
          free: []
        },
        Map.new(fields)
      )

  @doc "A sound event at the entity, with a fresh seed."
  def sound(id, source, volume, pitch), do: {:sound, id, source, volume, pitch, seed()}

  @doc """
  `canHaveALeashAttachedTo`: a living mob that takes a lead, within 12
  blocks of the holder (`%{x, y, z, width, height}`).
  """
  def attachable?(%{type: type} = body, {x, y, z}, holder) do
    {width, height, _} = Body.dimensions(body)

    leashable?(type) and Body.alive?(body) and
      between(%{x: x, y: y, z: z, width: width, height: height}, holder) <= 12.0
  end

  # `canBeLeashed`: its family takes a lead (`Native.mob_section_leashable/0`).
  defp leashable?(type) do
    types =
      case :persistent_term.get({__MODULE__, :leashable}, nil) do
        nil ->
          types = MapSet.new(Valimc.Native.mob_section_leashable())
          :persistent_term.put({__MODULE__, :leashable}, types)
          types

        types ->
          types
      end

    MapSet.member?(types, type)
  end

  # The distance between two bodies' box centres (`%{x, y, z, width, height}`).
  defp between(a, b) do
    {ax, ay, az} = center_of(a)
    {bx, by, bz} = center_of(b)
    :math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay) + (bz - az) * (bz - az))
  end

  # `AABB.getCenter` of `EntityDimensions.makeBoundingBox` (a float half width).
  defp center_of(%{x: x, y: y, z: z, width: width, height: height}) do
    half = Float32.round(width / 2.0)
    {lerp(x - half, x + half), lerp(y, y + height), lerp(z - half, z + half)}
  end

  defp lerp(a, b), do: a + 0.5 * (b - a)

  @doc "A fence knot at block `pos` with network id `id`, as a holder."
  def knot_holder({x, y, z}, id),
    do: %{x: x + 0.5, y: y + 0.375, z: z + 0.5, width: 0.375, height: 0.5, id: id}

  @doc "`setLeashedTo`: leashed to `holder` (network id `id`), keeping its momentum."
  def attach(%NativeBody{} = row, holder, id),
    do: %{row | leash: %{holder: holder, id: id, restored: false}}

  @doc """
  `dropLeash`: the lead gone, an item where the mob stands; its home gone.
  `{body, drops, free}` (`free`: a knot it let go).
  """
  def drop(body) do
    {body, [], free} = remove(body)
    {body, [{ItemStack.new("minecraft:lead"), {0.0, 0.0, 0.0}, nil}], free}
  end

  defp remove(%NativeBody{leash: leash} = row) do
    free = for %{holder: {:knot, pos}} <- [leash], do: pos
    {%{row | leash: nil}, [], free}
  end

  defp remove(%Body{mob: mob} = body) do
    free = for %{holder: {:knot, pos}} <- [mob.leash], do: pos
    {%{body | mob: %{mob | leash: nil, home: nil}}, [], free}
  end

  defp seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end

  @doc """
  `leashableInArea` around `center`: the mobs (`{id, body, position}`)
  whose box meets the 32-block box there and whose lead `holder` holds.
  """
  def leashed_to(mobs, holder, {cx, cy, cz}) do
    box = {cx - @area, cy - @area, cz - @area, cx + @area, cy + @area, cz + @area}

    for {_, body, {x, y, z}} = mob <- mobs,
        match?(%{holder: ^holder, restored: false}, leash(body)),
        meets?(box, body, {x, y, z}),
        do: mob
  end

  @doc "A body's lead (a native mob's as its row shows it), nil for none."
  def leash(%Body{mob: %Mob{leash: leash}}), do: leash
  def leash(%NativeBody{leash: leash}), do: leash
  def leash(_body), do: nil

  defp meets?({x0, y0, z0, x1, y1, z1}, body, {x, y, z}) do
    {width, height, _} = Body.dimensions(body)
    half = Valimc.Data.Float32.round(width / 2.0)

    x - half < x1 and x + half > x0 and y < y1 and y + height > y0 and z - half < z1 and
      z + half > z0
  end

  @doc """
  `LeadItem.bindPlayerMobs` at fence `pos` (its knot `knot`: `{id, existing}`):
  the player's mobs there that can reach it, each with its new body
  (`[{id, body}]`); none moves without a knot to move to.
  """
  def bind(mobs, player, {pos, knot_id}) do
    {x, y, z} = pos
    holder = knot_holder(pos, knot_id)

    for {id, body, position} <- leashed_to(mobs, {:player, player}, {x + 0.5, y + 0.5, z + 0.5}),
        attachable?(body, position, holder),
        do: {id, attach(body, {:knot, pos}, knot_id)}
  end

  @doc """
  `LeashFenceKnotEntity.interact` without shears: the player's mobs (around
  the player) that reach the knot move to it; if none and the player does
  not sneak, the knot's mobs that reach the player move to it. `[{id,
  body}]`, empty for a use that passes.
  """
  def knot(mobs, {pos, knot_id}, request) do
    holder = request.holder
    player = {:player, request.player}
    {cx, cy, cz} = center(holder)
    knot = knot_holder(pos, knot_id)

    to_knot =
      for {id, body, position} <- leashed_to(mobs, player, {cx, cy, cz}),
          attachable?(body, position, knot),
          do: {id, attach(body, {:knot, pos}, knot_id)}

    if to_knot != [] or request.sneaking do
      to_knot
    else
      {kx, ky, kz} = center(knot)

      for {id, body, position} <- leashed_to(mobs, {:knot, pos}, {kx, ky, kz}),
          attachable?(body, position, holder),
          do: {id, attach(body, player, holder.id)}
    end
  end

  defp center(%{x: x, y: y, z: z, height: height}), do: {x, y + height / 2.0, z}

  @doc "`shearOffAllLeashConnections` of a knot: its mobs let go, `[{id, body, drops}]`."
  def snip(mobs, pos, {kx, ky, kz}) do
    for {id, body, _} <- leashed_to(mobs, {:knot, pos}, {kx, ky, kz}) do
      {body, drops, _} = drop(body)
      {id, body, drops}
    end
  end

  @doc "Whether `item` is a lead or shears: `:lead`, `:shears` or nil."
  def tool(%ItemStack{item_id: @lead}), do: :lead
  def tool(%ItemStack{item_id: @shears}), do: :shears
  def tool(_item), do: nil
end
