defmodule Valimc.Entity.ShulkerBullet do
  @moduledoc """
  A shulker's bullet (VMC-043e, `ShulkerBullet`): a projectile body that
  flies through blocks along one axis at a time toward its target, picking
  its next direction every 10 to 50 ticks, when a block stands in its way or
  when it lines up with the target on its axis. It steers toward the
  direction's point (`targetDelta`, growing 2.5% a tick) while its target
  lives, else falls. What it hits takes 4 and floats up (Levitation for ten
  seconds); a block it hits stops it.

  Its data, beside a projectile's: its target (`{:player | :mob, uuid}`, nil
  once lost), its direction (`Direction`'s 3D value or nil), the steps
  until it turns, its target deltas, the deltas the kernel steers by this
  tick (`home`) and its own random (seeded from its uuid; vanilla's is
  unseeded).

  A target here is `%{uuid, position: {x, y, z}, box, alive, spectator}`
  and `read` gives the state at a cell (nil where it cannot be read).
  """
  alias Valimc.AI.Random
  alias Valimc.Data.BlockFacts
  alias Valimc.Entity.{Body, Projectile}

  @type_name "minecraft:shulker_bullet"
  @speed 0.15
  @gravity 0.04
  @steps {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}

  def type, do: @type_name

  @doc "Terminal hurt/block feedback, before the native callback discards the bullet."
  def feedback(:hurt, at) do
    [
      sound("minecraft:entity.shulker_bullet.hurt", at),
      {:particles, "minecraft:crit", at, {0.2, 0.2, 0.2}, 0.0, 15}
    ]
  end

  def feedback(:block, at) do
    [
      {:particles, "minecraft:explosion", at, {0.2, 0.2, 0.2}, 0.0, 2},
      sound("minecraft:entity.shulker_bullet.hit", at)
    ]
  end

  defp sound(name, at), do: {:sound_at, name, "hostile", at, 1.0, 1.0}

  @doc "Its own data and defaults."
  def data,
    do: %{target: nil, direction: nil, steps: 0, deltas: {0.0, 0.0, 0.0}, home: nil, random: 0}

  @doc """
  `new ShulkerBullet(level, shulker, target, avoidAxis)`: at `center` (its
  shooter's box centre), first heading up, then its first direction picked
  (never along `axis`, the axis of the face its shooter holds). Its random
  is seeded from `uuid` unless `random` is given.
  """
  def new(owner, center, target, axis, uuid, read, random \\ nil) do
    body = Projectile.new(@type_name, owner)

    data = %{
      body.data
      | target: target_ref(target),
        direction: 1,
        random: random || Random.new(uuid)
    }

    select(%{body | data: data}, center, axis, target, read)
  end

  defp target_ref(%{ref: ref}), do: ref
  defp target_ref(_), do: nil

  @doc """
  Before the kernel moves it: with a living target its deltas grow and the
  kernel steers by them (`home`), else it falls; a target no longer found
  is lost for good.
  """
  def prepare(%Body{data: data} = body, target) do
    data = if target == nil, do: %{data | target: nil}, else: data

    data =
      if target != nil and Map.get(target, :alive, true) and
           not Map.get(target, :spectator, false) do
        {x, y, z} = data.deltas
        clamp = fn v -> v |> Kernel.*(1.025) |> max(-1.0) |> min(1.0) end
        deltas = {clamp.(x), clamp.(y), clamp.(z)}
        %{data | deltas: deltas, home: deltas}
      else
        %{data | home: nil}
      end

    %{body | data: data}
  end

  @doc "The kernel's kind of a bullet (`Projectile.input/3`)."
  def kind(%Body{data: data, no_gravity: no_gravity}),
    do: {:bullet, {data.home, if(no_gravity, do: 0.0, else: @gravity)}}

  @doc """
  After the kernel moved it to `position` (when it hit nothing): its steps
  run down and it turns where it must.
  """
  def turn(body, _position, nil, _read), do: body

  def turn(%Body{data: data} = body, {x, y, z} = position, target, read) do
    body =
      if data.steps > 0 do
        steps = data.steps - 1
        body = %{body | data: %{data | steps: steps}}
        if steps == 0, do: select(body, position, axis(data.direction), target, read), else: body
      else
        body
      end

    case body.data.direction do
      nil ->
        body

      direction ->
        current = {floor(x), floor(y), floor(z)}
        axis = axis(direction)
        {tx, ty, tz} = block(target.position)
        {cx, cy, cz} = current

        cond do
          stands_on?(read, relative(current, direction)) ->
            select(body, position, axis, target, read)

          (axis == 0 and cx == tx) or (axis == 2 and cz == tz) or (axis == 1 and cy == ty) ->
            select(body, position, axis, target, read)

          true ->
            body
        end
    end
  end

  # `selectNextMoveDirection(avoidAxis, target)`.
  defp select(%Body{data: data} = body, {x, y, z} = position, avoid, target, read) do
    {offset, {tx, ty, tz} = target_pos} =
      case target do
        nil ->
          {px, py, pz} = block(position)
          {0.5, {px, py - 1, pz}}

        %{position: {ex, ey, ez}, box: {_, y0, _, _, y1, _}} ->
          offset = (y1 - y0) * 0.5
          {offset, block({ex, ey + offset, ez})}
      end

    {aim, direction, random} =
      if close?(target_pos, position) do
        {{tx + 0.5, ty + offset, tz + 0.5}, nil, data.random}
      else
        current = {cx, cy, cz} = block(position)

        options =
          [
            avoid != 0 and
              cond do
                cx < tx and empty?(read, relative(current, 5)) -> 5
                cx > tx and empty?(read, relative(current, 4)) -> 4
                true -> false
              end,
            avoid != 1 and
              cond do
                cy < ty and empty?(read, relative(current, 1)) -> 1
                cy > ty and empty?(read, relative(current, 0)) -> 0
                true -> false
              end,
            avoid != 2 and
              cond do
                cz < tz and empty?(read, relative(current, 3)) -> 3
                cz > tz and empty?(read, relative(current, 2)) -> 2
                true -> false
              end
          ]
          |> Enum.filter(&is_integer/1)

        {selection, random} = Random.int(data.random, 6)

        {selection, random} =
          case options do
            [] ->
              Enum.reduce_while(5..1//-1, {selection, random}, fn _, {selection, random} ->
                if empty?(read, relative(current, selection)),
                  do: {:halt, {selection, random}},
                  else: {:cont, Random.int(random, 6)}
              end)

            _ ->
              {n, random} = Random.int(random, length(options))
              {Enum.at(options, n), random}
          end

        {sx, sy, sz} = elem(@steps, selection)
        {{x + sx, y + sy, z + sz}, selection, random}
      end

    {ax, ay, az} = aim
    {xa, ya, za} = {ax - x, ay - y, az - z}
    distance = :math.sqrt(xa * xa + ya * ya + za * za)

    deltas =
      if distance == 0.0,
        do: {0.0, 0.0, 0.0},
        else: {xa / distance * @speed, ya / distance * @speed, za / distance * @speed}

    {n, random} = Random.int(random, 5)

    %{
      body
      | data: %{
          data
          | direction: direction,
            deltas: deltas,
            steps: 10 + n * 10,
            random: random,
            impulse: data.impulse + 1
        }
    }
  end

  # `BlockPos.closerToCenterThan(position, 2.0)`.
  defp close?({bx, by, bz}, {x, y, z}) do
    {dx, dy, dz} = {bx + 0.5 - x, by + 0.5 - y, bz + 0.5 - z}
    dx * dx + dy * dy + dz * dz < 4.0
  end

  defp block({x, y, z}), do: {floor(x), floor(y), floor(z)}

  defp axis(nil), do: nil
  defp axis(direction) when direction in [0, 1], do: 1
  defp axis(direction) when direction in [2, 3], do: 2
  defp axis(_direction), do: 0

  defp relative({x, y, z}, direction) do
    {dx, dy, dz} = elem(@steps, direction)
    {x + dx, y + dy, z + dz}
  end

  # `isEmptyBlock`: air (a cell it cannot read is not).
  defp empty?(read, cell) do
    case read.(cell) do
      nil -> false
      state -> BlockFacts.air?(state)
    end
  end

  # `loadedAndEntityCanStandOn`: the top of the cell's collision shape is
  # full.
  defp stands_on?(read, cell) do
    world = %Valimc.AI.World{read: read}
    Valimc.AI.Shapes.face_full?(world, cell, 1)
  end
end
