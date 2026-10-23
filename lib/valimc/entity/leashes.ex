defmodule Valimc.Entity.Leashes do
  @moduledoc """
  What players do with leads (VMC-043c3), for the owner of the bodies:

  - on a mob, `Entity.interact`'s lead part before the mob's own
    (`interact/3`): shears snip its lead, its holder unties it (the lead an
    item unless the player has infinite materials), a lead in hand leashes
    it to the player (from a knot, that lead an item first);
  - a fence's use (`LeadItem.bindPlayerMobs`, `bind/3`): the player's mobs
    around it move to the fence's knot, made where none is;
  - a fence knot's (`LeashFenceKnotEntity.interact`, `knot/3`): the player's
    mobs move to it, else (not sneaking) its mobs move to the player;
    shears snip its leads.

  `request` is the interaction's (`Valimc.Entity.Animals.Interaction`) with
  the player's body as a holder (`holder: %{id, x, y, z, width, height}`)
  and whether it sneaks. Mobs are `{id, body, {x, y, z}}`. A lead's holder
  is `{:player, uuid}` or `{:knot, pos}` (`Valimc.Entity.Mob`); the mob's
  own tick does the rest (`Valimc.AI.Leash`).
  """
  alias Valimc.AI.Leash
  alias Valimc.Entity.{Body, Mob}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @lead ItemTypes.id("minecraft:lead")
  @shears ItemTypes.id("minecraft:shears")
  @tied "minecraft:item.lead.tied"
  @untied "minecraft:item.lead.untied"
  @snip "minecraft:item.shears.snip"
  # `leashableInArea`: a 32-block box around the centre.
  @area 16.0

  @doc """
  A player's use on mob `body` at `position` (`Entity.interact`'s lead
  part): `:pass` or `{:ok, body, outcome}` (`Interaction.outcome/1`, with
  `free`: the knots it let go).
  """
  def interact(%Body{mob: %Mob{} = mob} = body, position, request) do
    leash = mob.leash
    item = request.item && request.item.item_id

    cond do
      not Mob.alive?(mob) ->
        :pass

      # `shearOffAllLeashConnections`: its snip where it stands.
      item == @shears and held?(leash) ->
        {body, drops, free} = drop(body)

        {:ok, body,
         Interaction.outcome(
           hand: {:wear, 1},
           events: [{:sound_block, @snip, "player", 1.0, 1.0, seed()}],
           drops: drops,
           free: free
         )}

      held?(leash) and leash.holder == {:player, request.player} ->
        {body, drops, free} =
          if request.infinite, do: remove(body), else: drop(body)

        {:ok, body, Interaction.outcome(events: [sound(@untied)], drops: drops, free: free)}

      item == @lead and not match?(%{holder: {:player, _}}, held(leash)) and
          attachable?(body, position, request.holder) ->
        {body, drops, free} = if held?(leash), do: drop(body), else: {body, [], []}
        body = attach(body, {:player, request.player}, request.holder.id)

        {:ok, body,
         Interaction.outcome(
           hand: {:use, 1},
           swing: true,
           events: [sound(@tied)],
           drops: drops,
           free: free
         )}

      true ->
        :pass
    end
  end

  def interact(_body, _position, _request), do: :pass

  # `isLeashed`: a holder found (a lead still looking for its holder is not).
  defp held?(%{restored: false}), do: true
  defp held?(_leash), do: false

  defp held(leash), do: if(held?(leash), do: leash)

  @doc """
  `canHaveALeashAttachedTo`: a living mob that takes a lead, within 12
  blocks of the holder (`%{x, y, z, width, height}`).
  """
  def attachable?(%Body{type: type, mob: mob} = body, {x, y, z}, holder) do
    {width, height, _} = Body.dimensions(body)

    Leash.leashable?(type) and Mob.alive?(mob) and
      Leash.between(%{x: x, y: y, z: z, width: width, height: height}, holder) <= 12.0
  end

  @doc "`setLeashedTo`: leashed to `holder` (network id `id`), keeping its momentum."
  def attach(%Body{mob: mob} = body, holder, id) do
    momentum = if mob.leash, do: mob.leash.momentum, else: 0.0
    leash = %{holder: holder, id: id, momentum: momentum, restored: false}
    %{body | mob: %{mob | leash: leash}}
  end

  @doc """
  `dropLeash`: the lead gone, an item where the mob stands; its home gone.
  `{body, drops, free}` (`free`: a knot it let go).
  """
  def drop(body) do
    {body, [], free} = remove(body)
    {body, [{ItemStack.new("minecraft:lead"), {0.0, 0.0, 0.0}, nil}], free}
  end

  defp remove(%Body{mob: mob} = body) do
    free = for %{holder: {:knot, pos}} <- [mob.leash], do: pos
    {%{body | mob: %{mob | leash: nil, home: nil}}, [], free}
  end

  defp sound(name), do: {:sound, name, "neutral", 1.0, 1.0, seed()}

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

    for {_, %Body{mob: %Mob{leash: %{holder: ^holder, restored: false}}} = body, {x, y, z}} =
          mob <- mobs,
        meets?(box, body, {x, y, z}),
        do: mob
  end

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
    holder = Leash.knot_holder(pos, knot_id)

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
    knot = Leash.knot_holder(pos, knot_id)

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
