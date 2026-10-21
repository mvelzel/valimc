defmodule Valimc.Physics.ItemStep do
  @moduledoc """
  Item ticks through the physics kernel (VMC-077l): vanilla's `ItemEntity.tick`
  movement (currents, gravity or buoyancy, collision with blocks and the
  border, bounce, block speed and friction) for many items in one call. The
  region owner runs it in its items phase; ageing stays here. An item the
  kernel cannot step (embedded in a block, near a chunk that cannot be read,
  out of bounds) keeps its state.
  """
  alias Valimc.ItemMotionState
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
  The next state of each `%{position, motion: %ItemMotionState{}}` (other keys
  pass through): `{:ok, item}` or `{:error, reason}` per item, in order.
  """
  def run(view, items, border) do
    inputs =
      Enum.map(items, fn %{position: {x, y, z}, motion: m} ->
        {{x * 1.0, y * 1.0, z * 1.0}, m.velocity, m.on_ground, m.no_gravity}
      end)

    {:ok, results} = Kernel.items(view, inputs, border)

    Enum.zip_with(items, results, fn item, result ->
      case result do
        {:ok, position, velocity, on_ground} ->
          {:ok,
           %{
             item
             | position: position,
               motion: %{
                 ItemMotionState.tick(item.motion)
                 | velocity: velocity,
                   on_ground: on_ground
               }
           }}

        :inside ->
          {:error, :item_inside_block}

        :limit ->
          {:error, :item_motion_limit}

        {:unreadable, position} ->
          {:error, {:missing_block, position}}
      end
    end)
  end
end
