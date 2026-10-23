defmodule Valimc.World.Explosion do
  @moduledoc """
  An explosion (VMC-050a), as vanilla's `ServerExplosion.explode` runs it,
  in three parts:

  - **Reach.** The physics kernel casts the rays over the published rows
    (`Physics.Kernel.explosion/6`): the cells they reach, air included, as
    they stood when it went off.
  - **Entities.** Each owner whose entities lie in the reach box hits its
    own (`hits/3`): items and orbs an explosion of more than 4 damage
    destroys (their 5 health, `ItemEntity.hurtServer`; a nether star
    resists), mobs are hurt, and everything left is pushed. Players are hit
    by their sessions (`Valimc.Player.Explosions`), so their hosts decide
    damage, knockback and the packet.
  - **Blocks.** The crater commits as one box edit across every owner it
    touches (`Valimc.World.BoxEdit`), from a job off the owner (`work/2`):
    its cells turn to air with the expected states they had, their loot
    (the tool-less mining loot, each item surviving `1 / radius` when the
    explosion decays drops) merges into stacks of at most 16 that pop at
    the first cell of each, and TNT it reaches primes with a short fuse
    (`TntBlock.wasExploded`). A cell whose state changed since is read
    again and planned from what stands there. Cells with a block entity
    are left standing (their contents need the container spill).

  An explosion with `fire` (a ghast's fireball, VMC-037o) lights a third
  of its air cells over a solid block (`createFire`). Entity sources (who
  lit the TNT) come with their sources.
  """
  import Bitwise
  alias Valimc.Blocks.MiningLoot
  alias Valimc.Data.{BlockFacts, Blocks, Float32, Grid}
  alias Valimc.Entity.{Body, ItemDrop, ItemMotionState, Store}
  alias Valimc.Living.{Armor, Explosions}
  alias Valimc.Physics.Kernel
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{BoxEdit, Dimension, GameRules}

  defstruct [:center, :radius, decay: true, interacts: true, fire: false]

  @tnt_offset Float32.round(0.98) * 0.0625
  @air Blocks.default_state("air")

  @doc """
  A primed TNT's explosion at its position `{x, y, z}` (`PrimedTnt.explode`:
  power 4 at `getY(0.0625)`, drops decaying by the TNT game rule).
  """
  def tnt({x, y, z}),
    do: %__MODULE__{
      center: {x, y + @tnt_offset, z},
      radius: 4.0,
      decay: GameRules.get(:tnt_explosion_drop_decay)
    }

  @doc "Whether the explosion shows its small particle (`ServerExplosion.isSmall`)."
  def small?(%__MODULE__{radius: radius, interacts: interacts}),
    do: radius < 2.0 or not interacts

  @doc """
  The cells the explosion's rays reach in the current dimension, with their
  states: `{:ok, cells}`.
  """
  def reach(%__MODULE__{center: center, radius: radius}, seed \\ random_seed()) do
    {min_y, height} = Dimension.bounds(Dimension.current())

    with {:ok, {cells, _unreadable}} <-
           Kernel.explosion(Valimc.World.View.new(), center, radius, seed, min_y, height),
         do: {:ok, cells}
  end

  @doc """
  What the explosion does to entries of an owner's store (`id => entry`):
  `[{id, action}]` with `:destroy`, `{:push, impulse}` or `{:hurt, amount,
  impulse}`. Entries outside its reach box or past twice its radius are left
  out.
  """
  def hits(%__MODULE__{center: center, radius: radius} = explosion, entries) do
    {x0, y0, z0, x1, y1, z1} = Explosions.reach(radius, center)

    candidates =
      for {id, %{entity: %{x: x, y: y, z: z}} = entry} <- entries,
          box = box(entry),
          intersects?(box, {x0, y0, z0, x1, y1, z1}),
          distance = Explosions.distance(radius, center, {x, y, z}),
          distance != nil,
          do: {id, entry, box, distance}

    {:ok, seen} =
      Kernel.exposure(Valimc.World.View.new(), center, Enum.map(candidates, &elem(&1, 2)))

    Enum.zip_with(candidates, seen, fn {id, entry, _box, distance}, seen ->
      {id, action(explosion, entry, distance, seen)}
    end)
  end

  defp action(explosion, %{kind: kind, entity: %{x: x, y: y, z: z}} = entry, distance, seen) do
    damage = Explosions.damage(explosion.radius, explosion.center, {x, y, z}, seen)
    origin = origin(entry)
    resistance = knockback_resistance(entry)
    impulse = Explosions.knockback(explosion.center, origin, distance, seen, resistance)

    cond do
      kind == :item and not Armor.resists_explosion?(entry.stack) and damage > 4.0 -> :destroy
      kind == :orb and damage > 4.0 -> :destroy
      kind == :mob -> {:hurt, damage, impulse}
      true -> {:push, impulse}
    end
  end

  @doc """
  Apply `hits/2`'s actions to `store` (section `key`): `{store, removed}`,
  `removed` the handles of entities to remove once durable.
  """
  def apply_hits(store, key, actions) do
    Enum.reduce(actions, store, fn {id, action}, acc ->
      case {action, acc.entries[id]} do
        {_, nil} ->
          acc

        {:destroy, %{revision: revision}} ->
          case Store.remove(acc, acc.epoch, id, revision) do
            {:ok, next} -> next
            _ -> acc
          end

        {{:hurt, amount, impulse}, %{body: body}} ->
          {hurt, events} = Body.hurt(body, :explosion, amount)
          Store.change_body(acc, id, Body.push(hurt, impulse), events)

        {{:push, impulse}, %{body: %Body{} = body}} ->
          Store.change_body(acc, id, Body.push(body, impulse))

        {{:push, impulse}, %{entity: entity, revision: revision} = entry} ->
          motion = Map.get(entry, :motion, %ItemMotionState{})
          {vx, vy, vz} = motion.velocity
          {dx, dy, dz} = impulse
          motion = %{motion | velocity: {vx + dx, vy + dy, vz + dz}}

          step = %{
            id: id,
            revision: revision,
            position: {entity.x, entity.y, entity.z},
            motion: motion
          }

          case Store.advance(acc, key, acc.epoch, [step]) do
            {:ok, next, _} -> next
            _ -> acc
          end
      end
    end)
  end

  @doc "The section keys (`{sx, sz}`) whose entities the explosion's reach box may hold."
  def sections(%__MODULE__{center: center, radius: radius}) do
    {x0, _, z0, x1, _, z1} = Explosions.reach(radius, center)
    chunk = fn v -> Integer.floor_div(floor(v), 16) end

    for cx <- chunk.(x0)..chunk.(x1),
        cz <- chunk.(z0)..chunk.(z1),
        uniq: true,
        do: Grid.region_key({cx, cz})
  end

  @doc "Whether store `entry`'s box meets `box` (`{x0, y0, z0, x1, y1, z1}`)."
  def box_hit?(entry, box), do: intersects?(box(entry), box)

  # An entity's box and the point it is pushed from.
  defp box(%{kind: kind, entity: %{x: x, y: y, z: z}} = entry) do
    {width, height} = size(kind, entry)
    {x - width / 2, y, z - width / 2, x + width / 2, y + height, z + width / 2}
  end

  defp size(:item, _), do: fact_size("minecraft:item")
  defp size(:orb, _), do: fact_size("minecraft:experience_orb")
  defp size(_, %{body: %Body{type: type}}), do: fact_size(type)

  defp fact_size(type) do
    facts = Valimc.Data.EntityTypes.fetch(type)
    {facts.width, facts.height}
  end

  defp origin(%{entity: %{x: x, y: y, z: z}, body: %Body{type: "minecraft:tnt"}}), do: {x, y, z}

  defp origin(%{kind: kind, entity: %{x: x, y: y, z: z}} = entry) do
    type =
      case {kind, entry} do
        {:item, _} -> "minecraft:item"
        {:orb, _} -> "minecraft:experience_orb"
        {_, %{body: body}} -> body.type
      end

    {x, y + Valimc.Data.EntityTypes.fetch(type).eye_height, z}
  end

  defp knockback_resistance(%{body: %Body{type: type, mob: %{attributes: attributes}}}),
    do: Valimc.Entity.Mob.base(type, attributes, "minecraft:explosion_knockback_resistance")

  defp knockback_resistance(_entry), do: 0.0

  defp intersects?({a0, b0, c0, a1, b1, c1}, {x0, y0, z0, x1, y1, z1}),
    do: a0 < x1 and a1 > x0 and b0 < y1 and b1 > y0 and c0 < z1 and c1 > z0

  ## Blocks

  @doc """
  The crater's plan from `cells` (`{position, state}`, as `reach/2` found
  them) for `dimension`: the box edit's parts by region key, with each part's
  edits, expected states and the entity records (drops and primed TNT) it
  adopts.
  """
  def plan(%__MODULE__{} = explosion, cells) do
    targets =
      cells
      |> Enum.reject(fn {_, state} ->
        BlockFacts.air?(state) or BlockFacts.flag?(state, :block_entity)
      end)
      |> Enum.shuffle()

    {records, stacks} =
      Enum.reduce(targets, {[], []}, fn {position, state}, {records, stacks} ->
        cond do
          not explosion.interacts ->
            {records, stacks}

          Blocks.name(Blocks.block_id(state)) == "tnt" ->
            if GameRules.get(:tnt_explodes),
              do: {[primed_tnt(position) | records], stacks},
              else: {records, stacks}

          true ->
            {records,
             Enum.reduce(drops(explosion, state, position), stacks, &collect(&2, &1, position))}
        end
      end)

    records =
      records ++ Enum.map(stacks, fn {position, stack} -> ItemDrop.pop(position, stack) end)

    states = Map.new(targets)
    edits = if explosion.interacts, do: Map.new(targets, fn {p, _} -> {p, @air} end), else: %{}

    parts =
      edits
      |> Map.keys()
      |> Enum.group_by(&region/1)
      |> Map.new(fn {key, positions} ->
        {key,
         %{edits: Map.take(edits, positions), expected: Map.take(states, positions), entities: []}}
      end)

    Enum.reduce(records, parts, fn %{x: x, z: z} = record, acc ->
      key = region({floor(x), 0, floor(z)})
      part = Map.get(acc, key, %{edits: %{}, expected: %{}, entities: []})
      Map.put(acc, key, %{part | entities: [record | part.entities]})
    end)
  end

  defp region({x, _, z}), do: Grid.region_key(Grid.chunk_key(x, z))

  # The block's tool-less loot with its source as breaker; with decay the
  # table's `survives_explosion` and `explosion_decay` read the radius.
  defp drops(explosion, state, position) do
    case MiningLoot.drops(state, position,
           entity: true,
           radius: if(explosion.decay, do: explosion.radius)
         ) do
      {:ok, stacks} -> stacks
      {:error, _} -> []
    end
  end

  # `addOrAppendStack`: a drop merges into the collected stacks in order
  # (`ItemEntity.merge` up to 16, when both fit one stack), and what is left
  # starts a stack at its cell.
  defp collect(stacks, stack, position) do
    {stacks, left} =
      Enum.map_reduce(stacks, stack, fn {at, held}, left ->
        if left.count > 0 and ItemStack.same_item?(held, left) and
             held.count + left.count <= ItemStack.max_stack_size(held) do
          moved = max(0, min(min(ItemStack.max_stack_size(held), 16) - held.count, left.count))
          {{at, %{held | count: held.count + moved}}, %{left | count: left.count - moved}}
        else
          {{at, held}, left}
        end
      end)

    if left.count > 0, do: stacks ++ [{position, left}], else: stacks
  end

  # `TntBlock.wasExploded`: a primed TNT with a fuse of 10 to 29 ticks
  # (`getRandomShortFuse`).
  defp primed_tnt(position), do: primed_record(position, :rand.uniform(20) - 1 + 10)

  @doc "The record of a primed TNT with `fuse` at cell `{x, y, z}`'s bottom centre."
  def primed_record({x, y, z}, fuse),
    do:
      Store.body_record(
        Body.primed_tnt(fuse),
        :crypto.strong_rand_bytes(16),
        {x + 0.5, y * 1.0, z + 0.5}
      )

  @doc """
  The job that commits the craters of `explosions` (`[{explosion, cells}]`)
  in `dimension` in order: `{:ok, committed}` with the count committed.
  """
  def work(dimension, explosions) do
    fn ->
      {:ok, Enum.count(explosions, fn {e, cells} -> commit(dimension, e, cells, 3) == :ok end)}
    end
  end

  @doc """
  `createFire` over a crater's `parts`: each reached cell left air lights,
  one in three, over a block that renders solid (read where the reach did
  not cover it), as `BaseFireBlock.getState` picks the fire.
  """
  def fire(parts, %__MODULE__{fire: false}, _cells, _read), do: parts

  def fire(parts, %__MODULE__{}, cells, read) do
    states = Map.new(cells)
    edits = Enum.reduce(parts, %{}, fn {_, part}, acc -> Map.merge(acc, part.edits) end)
    after_edit = fn p -> Map.get(edits, p) || Map.get(states, p) || read.(p) end

    Enum.reduce(cells, parts, fn {{x, y, z} = position, state}, acc ->
      below = after_edit.({x, y - 1, z})

      if :rand.uniform(3) == 1 and BlockFacts.air?(Map.get(edits, position, state)) and
           below != nil and BlockFacts.flag?(below, :solid_render) do
        key = region(position)
        part = Map.get(acc, key, %{edits: %{}, expected: %{}, entities: []})

        Map.put(acc, key, %{
          part
          | edits: Map.put(part.edits, position, fire_state(below)),
            expected: Map.put_new(part.expected, position, state)
        })
      else
        acc
      end
    end)
  end

  @doc "`BaseFireBlock.getState` over a block that holds fire: soul fire on soul sand and soil."
  def fire_state(below) do
    if Blocks.name(Blocks.block_id(below)) in ["soul_sand", "soul_soil"],
      do: Blocks.default_state("soul_fire"),
      else: Blocks.default_state("fire")
  end

  defp commit(dimension, explosion, cells, retries) do
    read = fn position ->
      case BoxEdit.read(dimension, position, position) do
        {:ok, %{^position => state}} -> state
        _ -> nil
      end
    end

    parts = explosion |> plan(cells) |> fire(explosion, cells, read)

    case BoxEdit.commit(dimension, parts) do
      :ok ->
        :ok

      {:error, :stale_revision} when retries > 0 ->
        commit(dimension, explosion, reread(dimension, cells), retries - 1)

      {:error, {:retry, _}} when retries > 0 ->
        Process.sleep(10)
        commit(dimension, explosion, cells, retries - 1)

      error ->
        error
    end
  end

  # What stands in the reached cells now (a cell that cannot be read drops out).
  defp reread(dimension, cells) do
    Enum.flat_map(cells, fn {position, _} ->
      case BoxEdit.read(dimension, position, position) do
        {:ok, %{^position => state}} -> [{position, state}]
        _ -> []
      end
    end)
  end

  defp random_seed, do: :rand.uniform(1 <<< 62) - 1
end
