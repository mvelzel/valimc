defmodule Valimc.World.BlockBodies do
  @moduledoc """
  The ticks of block-like bodies a region owner runs in its items phase
  (VMC-050a), each moved through the physics kernel
  (`Physics.Kernel.block_bodies/3`):

  - A primed TNT burns its fuse and explodes once it runs out
    (`PrimedTnt.tick`).
  - A falling block counts its time and fall distance and, on the ground
    (or concrete powder in water), lands where it can or drops as an item
    (`FallingBlockEntity.tick`, the rules in `Valimc.Blocks.FallingBlock`);
    one that falls for more than 100 ticks below or above the world, or for
    600 ticks, drops. An anvil that lands after falling hurts the living
    entities in its box (2 per block past the first, at most 40) and may
    chip or break (`AnvilBlock.damage`).

  A body the kernel cannot step (a cell it cannot read, past its bounds)
  stays where it is; its fuse and time go on.
  """
  alias Valimc.Blocks.FallingBlock
  alias Valimc.Data.{BlockFacts, Blocks, Grid}
  alias Valimc.Entity.Body
  alias Valimc.Physics.Kernel

  @types ["minecraft:tnt", "minecraft:falling_block"]
  @kinds %{"minecraft:tnt" => :tnt, "minecraft:falling_block" => :falling_block}

  # Anvils as vanilla wears them: damaged one step further, the last breaks.
  @anvils %{
    "anvil" => "chipped_anvil",
    "chipped_anvil" => "damaged_anvil",
    "damaged_anvil" => nil
  }

  @doc "Whether bodies of `type` tick here."
  def ticks?(type), do: type in @types

  @doc """
  One tick of `bodies` (`[{id, entry}]`), reading the owner's cells with
  `read` (nil outside it): a list of outcomes, in order,

  - `{:moved, id, revision, position, body}` for a body still going,
  - `{:explode, id, revision, position}` for a TNT whose fuse ran out,
  - `{:land, id, revision, cell, state, events}` for a block placed,
  - `{:drop, id, revision, position, state, events}` for one dropping its item,
  - `{:discard, id, revision, position, events}` for one gone without either,

  with `events` the level events it raises there, and `{:hurt, box, amount}`
  before an anvil's landing for the living entities it falls on.
  """
  def tick([], _border, _read), do: []

  def tick(bodies, border, read) do
    inputs =
      Enum.map(bodies, fn {_, %{entity: e, body: body}} ->
        {{e.x * 1.0, e.y * 1.0, e.z * 1.0}, body.velocity, body.on_ground, body.no_gravity,
         Map.fetch!(@kinds, body.type)}
      end)

    {:ok, results} = Kernel.block_bodies(Valimc.World.View.new(), inputs, border)

    Enum.flat_map(Enum.zip(bodies, results), fn {{id, %{entity: e, body: body} = entry}, result} ->
      {position, moved_y, body} =
        case result do
          {:ok, position, velocity, on_ground, moved_y} ->
            {position, moved_y, %{body | velocity: velocity, on_ground: on_ground}}

          _ ->
            {{e.x, e.y, e.z}, 0.0, body}
        end

      outcome(body, id, entry.revision, position, moved_y, read)
    end)
  end

  defp outcome(%Body{type: "minecraft:tnt"} = body, id, revision, position, _moved_y, _read) do
    fuse = body.data.fuse - 1

    if fuse <= 0,
      do: [{:explode, id, revision, position}],
      else: [{:moved, id, revision, position, %{body | data: %{body.data | fuse: fuse}}}]
  end

  defp outcome(%Body{data: data} = body, id, revision, {x, y, z} = position, moved_y, read) do
    if BlockFacts.air?(data.block_state) do
      [{:discard, id, revision, position, []}]
    else
      data = %{data | time: data.time + 1}
      cell = {floor(x), floor(y), floor(z)}
      stuck = FallingBlock.powder?(data.block_state) and FallingBlock.water?(read.(cell) || 0)

      cond do
        not body.on_ground and not stuck ->
          data =
            if moved_y < 0, do: %{data | fall_distance: data.fall_distance - moved_y}, else: data

          if out_of_time?(data.time, elem(cell, 1)),
            do: [drop(id, revision, position, data)],
            else: [{:moved, id, revision, position, %{body | data: data}}]

        true ->
          {hits, data} = if body.on_ground, do: fall_damage(data, position), else: {[], data}
          hits ++ [land(id, revision, position, cell, data, read)]
      end
    end
  end

  # `time > 100` below or above the world, or `time > 600` anywhere.
  defp out_of_time?(time, y),
    do: (time > 100 and (y <= Grid.min_y() or y > Grid.max_y())) or time > 600

  defp land(id, revision, position, {x, y, z} = cell, data, read) do
    current = read.(cell)

    cond do
      current != nil and Blocks.name(Blocks.block_id(current)) == "moving_piston" ->
        {:discard, id, revision, position, []}

      data.cancel_drop ->
        {:discard, id, revision, position, broken(data.block_state)}

      current == nil ->
        drop(id, revision, position, data)

      true ->
        sides =
          for {dx, dy, dz, toward} <- [
                {0, 1, 0, :sturdy_down},
                {0, 0, -1, :sturdy_south},
                {0, 0, 1, :sturdy_north},
                {-1, 0, 0, :sturdy_east},
                {1, 0, 0, :sturdy_west}
              ] do
            neighbour = read.({x + dx, y + dy, z + dz}) || 0
            {neighbour, BlockFacts.flag?(neighbour, toward)}
          end

        case FallingBlock.landing(data.block_state, current, read.({x, y - 1, z}) || 0, sides) do
          {:place, state} -> {:land, id, revision, cell, state, landed(data.block_state)}
          :drop -> drop(id, revision, position, data)
        end
    end
  end

  defp drop(id, revision, position, data) do
    if data.drops and Valimc.World.GameRules.get(:entity_drops),
      do: {:drop, id, revision, position, data.block_state, broken(data.block_state)},
      else: {:discard, id, revision, position, []}
  end

  # `causeFallDamage` of a block that hurts (an anvil): the living entities
  # in its box take 2 per block fallen past the first, at most 40, and the
  # anvil wears with a chance of 5% plus 5% per block.
  defp fall_damage(%{hurts: false} = data, _position), do: {[], data}

  defp fall_damage(data, {x, y, z}) do
    blocks = trunc(Float.ceil(data.fall_distance - 1.0))
    damage = min(floor(blocks * 2.0), 40) * 1.0

    if blocks < 0 or damage <= 0.0 do
      {[], data}
    else
      box = {x - 0.49, y, z - 0.49, x + 0.49, y + 0.98, z + 0.49}

      data =
        if :rand.uniform() < 0.05 + blocks * 0.05 do
          case Map.fetch!(@anvils, Blocks.name(Blocks.block_id(data.block_state))) do
            nil -> %{data | cancel_drop: true}
            next -> %{data | block_state: Blocks.state(next, facing(data.block_state))}
          end
        else
          data
        end

      {[{:hurt, box, damage}], data}
    end
  end

  defp facing(state), do: Map.take(Blocks.properties(state), ["facing"])

  # The level events of an anvil that lands (1031) or breaks (1029).
  defp landed(state), do: if(anvil?(state), do: [1031], else: [])
  defp broken(state), do: if(anvil?(state), do: [1029], else: [])
  defp anvil?(state), do: Blocks.class(state) == "AnvilBlock"
end
