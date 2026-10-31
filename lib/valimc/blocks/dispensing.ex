defmodule Valimc.Blocks.Dispensing do
  @moduledoc """
  What a dispenser does with an item and where it puts it (VMC-049a), from
  DispenserOracle's facts (`priv/physics/dispensers.json`: vanilla's
  `DispenserBlock.getDispenseMethod` for every item's default stack):

  - `:drop` (`DefaultDispenseItemBehavior`): one item flies out;
  - `{:projectile, config}` (`ProjectileDispenseBehavior`): the entity it
    shoots, power, spread, level event and start offset per facing;
  - `:equipment` (`EquipmentDispenseItemBehavior`): worn by a mob in front;
  - `:tnt`, `{:pour, fluid}` (water and lava buckets), `:fill` (an empty
    bucket), `:bone_meal`: the registered behaviours ValiMC performs;
  - `:unsupported`: a registered behaviour ValiMC does not perform yet
    (boats, minecarts, shulker boxes, shears, flint and steel, spawn eggs,
    glass bottles, fish buckets...), which keeps the item and fails.

  A dropper always drops (`DropperBlock`), into a container in front first.
  Sulfur cubes, which take their swallowable blocks from a dispenser, do not
  exist in ValiMC, so those blocks drop as vanilla drops them without one.
  """
  use Valimc.Data.Facts, "physics/dispensers.json"
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @sulfur "net.minecraft.core.dispenser.SulfurCubeBlockDispenseItemBehavior"
  @registered %{
    "tnt" => :tnt,
    "water_bucket" => {:pour, 2},
    "lava_bucket" => {:pour, 4},
    "bucket" => :fill,
    "bone_meal" => :bone_meal
  }
  @projectiles ~w(minecraft:arrow minecraft:snowball minecraft:egg minecraft:splash_potion
                  minecraft:lingering_potion minecraft:small_fireball)

  projectile = fn
    _, false ->
      :unsupported

    p, true ->
      <<power::float-32>> = <<p["power"]::32>>
      <<uncertainty::float-32>> = <<p["uncertainty"]::32>>

      {:projectile,
       %{
         entity: p["entity"],
         power: power,
         uncertainty: uncertainty,
         event: p["event"],
         offsets: List.to_tuple(Enum.map(p["offsets"], &List.to_tuple/1))
       }}
  end

  sulfur = @sulfur
  projectiles = @projectiles
  registered = @registered

  @behaviours (for {name, entry} <- @facts["items"], into: %{} do
                 behaviour =
                   case entry do
                     %{"kind" => "equipment", "dispensable" => dispensable} ->
                       if dispensable, do: :equipment, else: :drop

                     # Shot entities ValiMC has no body for yet (spectral
                     # arrows, bottles o' enchanting, fireworks, wind
                     # charges) are not dispensed.
                     %{"kind" => "projectile", "entity" => entity} = p ->
                       projectile.(p, entity in projectiles)

                     %{"kind" => "registered", "class" => ^sulfur} ->
                       :drop

                     %{"kind" => "registered"} ->
                       Map.get(registered, name, :unsupported)

                     _ ->
                       :unsupported
                   end

                 {ItemTypes.id(name), behaviour}
               end)

  unless Enum.all?(Map.keys(@registered), &(@behaviours[ItemTypes.id(&1)] == @registered[&1])) and
           match?({:projectile, %{entity: "minecraft:arrow"}}, @behaviours[ItemTypes.id("arrow")]),
         do: raise("Wrong dispenser facts")

  # `Direction.get3DDataValue` order.
  @faces [{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}]

  @doc "A dispenser's behaviour for `stack` (`getDispenseMethod`)."
  def behaviour(%ItemStack{item_id: item}), do: Map.get(@behaviours, item, :drop)

  @doc "A facing's `get3DDataValue` (the smoke's direction, level event 2000)."
  def face(step), do: Enum.find_index(@faces, &(&1 == step))

  @doc """
  `DispenserBlockEntity.getRandomSlot`: a slot holding a stack, each with the
  same chance (`random.(n)` draws `0..n-1`), or nil when all are empty.
  """
  def random_slot(slots, random) do
    slots
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce({nil, 1}, fn
      {nil, _}, acc ->
        acc

      {_stack, index}, {chosen, odds} ->
        {if(random.(odds) == 0, do: index, else: chosen), odds + 1}
    end)
    |> elem(0)
  end

  @doc """
  `DefaultDispenseItemBehavior.spawnItem`'s start and velocity for an item
  dispensed from `cell` facing `step` (`getDispensePosition` 0.7 out, lowered
  by half the item's height, 6 accuracy), drawing on `float.()` in `[0, 1)`.
  """
  def drop({x, y, z}, {sx, sy, sz} = _step, float) do
    lower = if sy != 0, do: 0.125, else: 0.15625
    position = {x + 0.5 + 0.7 * sx, y + 0.5 + 0.7 * sy - lower, z + 0.5 + 0.7 * sz}
    pow = float.() * 0.1 + 0.2
    spread = 0.0172275 * 6
    triangle = fn mean -> mean + spread * (float.() - float.()) end
    vx = triangle.(sx * pow)
    vy = triangle.(0.2)
    vz = triangle.(sz * pow)
    {position, {vx, vy, vz}}
  end

  @doc "Where a projectile starts from `cell` facing `step` (its config's offset)."
  def launch({x, y, z}, step, %{offsets: offsets}) do
    {ox, oy, oz} = elem(offsets, face(step))
    {x + 0.5 + ox, y + 0.5 + oy, z + 0.5 + oz}
  end

  @doc """
  `DispenserBlockEntity.insertItem`: `stack` merged into the first slots that
  take it, then empty ones; `{slots, rest}` (rest nil when all fit).
  """
  def insert(slots, stack) do
    max = ItemStack.max_stack_size(stack)

    Enum.reduce_while(0..(tuple_size(slots) - 1), {slots, stack}, fn index, {slots, stack} ->
      target = elem(slots, index)

      if target == nil or ItemStack.same_item?(stack, target) do
        held = if target, do: target.count, else: 0
        moved = min(stack.count, max - held)

        slots =
          if moved > 0,
            do: put_elem(slots, index, %{stack | count: held + moved}),
            else: slots

        rest = if moved == stack.count, do: nil, else: %{stack | count: stack.count - moved}
        if rest == nil, do: {:halt, {slots, nil}}, else: {:cont, {slots, rest}}
      else
        {:cont, {slots, stack}}
      end
    end)
  end
end
