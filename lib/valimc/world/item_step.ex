defmodule Valimc.World.ItemStep do
  @moduledoc """
  Item ticks through the physics kernel (VMC-077l): vanilla's `ItemEntity.tick`
  movement (currents, gravity or buoyancy, collision with blocks and the
  border, bounce, block speed and friction) for many items in one call. The
  region owner runs it in its items phase; ageing stays here. An item the
  kernel cannot step (embedded in a block, near a chunk that cannot be read,
  out of bounds) keeps its state.
  """
  alias Valimc.Entity.{ItemBurning, ItemMotionState}
  alias Valimc.Physics.Kernel

  @doc """
  The items a region owner's tick moves: each item `%{position, motion}`
  stepped over published rows and the current border, those the kernel could
  not step left out.
  """
  def steps(items) do
    for {:ok, item} <- run(Valimc.World.View.new(), items, Valimc.World.Clock.border_snapshot()),
        ItemMotionState.valid?(item.motion),
        do: item
  end

  @doc """
  The experience orbs a region owner's tick moves (VMC-077i): each orb
  `%{position, motion, target}` stepped like `steps/1`'s items, pulled toward
  its `target` (nil when it follows no player), jumping at random in lava.
  """
  def orb_steps(orbs) do
    for {:ok, orb} <-
          run_orbs(Valimc.World.View.new(), orbs, Valimc.World.Clock.border_snapshot()),
        ItemMotionState.valid?(orb.motion),
        do: orb
  end

  @doc """
  The next state of each orb `%{position, motion, target}`, as `run/3`'s for
  items. An orb's optional `draws` (four integers below 2^24) are the jump in
  lava's `nextFloat` draws; fresh random ones otherwise.
  """
  def run_orbs(view, orbs, border) do
    inputs =
      Enum.map(orbs, fn %{position: {x, y, z}, motion: m} = orb ->
        draws = Map.get_lazy(orb, :draws, fn -> {draw(), draw(), draw(), draw()} end)
        {{x * 1.0, y * 1.0, z * 1.0}, m.velocity, m.on_ground, Map.get(orb, :target), draws}
      end)

    {:ok, results} = Kernel.orbs(view, inputs, border)
    Enum.zip_with(orbs, results, &result(&1, &2, false))
  end

  @doc """
  The next state of each `%{position, motion: %ItemMotionState{}}` (other keys
  pass through; `fire_immune` for one fire cannot hurt): `{:ok, item}` with
  `dead` whether it burned up, or `{:error, reason}` per item, in order.
  """
  def run(view, items, border) do
    inputs =
      Enum.map(items, fn %{position: {x, y, z}, motion: m} ->
        {{x * 1.0, y * 1.0, z * 1.0}, m.velocity, m.on_ground, m.no_gravity}
      end)

    {:ok, results} = Kernel.items(view, inputs, border)

    Enum.zip_with(items, results, &result(&1, &2, true))
  end

  defp draw, do: :rand.uniform(16_777_216) - 1

  # An item's counters tick with its motion; an orb's age is its owner's.
  # Both burn (VMC-034n4d): `dead` once fire, lava or a cactus took the last
  # of its health.
  defp result(entity, {:ok, position, velocity, on_ground, lava, fires}, counters) do
    motion = if counters, do: ItemMotionState.tick(entity.motion), else: entity.motion
    {motion, dead} = ItemBurning.tick(motion, Map.get(entity, :fire_immune, false), lava, fires)

    {:ok,
     Map.merge(entity, %{
       position: position,
       motion: %{motion | velocity: velocity, on_ground: on_ground},
       dead: dead
     })}
  end

  defp result(_entity, :inside, _), do: {:error, :item_inside_block}
  defp result(_entity, :limit, _), do: {:error, :item_motion_limit}
  defp result(_entity, {:unreadable, position}, _), do: {:error, {:missing_block, position}}
end
