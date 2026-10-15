defmodule Valimc.PlayerAir do
  @moduledoc "Bounded player air primitives; the owner supplies fresh contact, ticks and random draws."
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack
  alias Valimc.Physics.FluidContact
  @maximum 300
  @bubble_states [18651, 18652]

  def maximum, do: @maximum
  def valid?(air), do: is_integer(air) and air in -20..@maximum
  def bubble_states, do: @bubble_states
  def supply(player), do: Map.get(player, :air_supply, @maximum)

  def submerged?(frame, %{box: box, eye: {x, y, z} = eye}) do
    with {:ok, eyes} <- FluidContact.eyes(frame, box, eye),
         {:ok, state} <- Map.fetch(frame.states, {floor(x), floor(y), floor(z)}) do
      {:ok, eyes.water and state not in @bubble_states}
    else
      :error -> {:error, :incomplete_air_frame}
      error -> error
    end
  end

  def tick(air, true, false, oxygen, draw) do
    decreased = decrease(air, oxygen, draw)
    if drowning?(decreased), do: {0, 2.0}, else: {decreased, 0.0}
  end

  def tick(air, true, true, _oxygen, _draw), do: {air, 0.0}
  def tick(air, false, _immune, _oxygen, _draw), do: {increase(air), 0.0}

  # The pinned Respiration attribute effect applies to the head slot only.
  # Other native items/enchantments contribute no default oxygen modifier.
  def oxygen_bonus(%Inventory{slots: slots}) do
    case slots[5] do
      %ItemStack{components: components} ->
        components
        |> Map.get("minecraft:enchantments", %{})
        |> Map.get("minecraft:respiration", 0)

      nil ->
        0
    end
  end

  def decrease(air, oxygen, draw)
      when is_integer(air) and air in -20..@maximum and is_number(oxygen) and
             oxygen >= 0 and oxygen <= 1024 and is_number(draw) and draw >= 0 and draw < 1 do
    if oxygen > 0 and draw >= 1.0 / (oxygen + 1.0), do: air, else: air - 1
  end

  def increase(air) when is_integer(air) and air in -20..@maximum,
    do: min(@maximum, air + 4)

  def drowning?(air) when is_integer(air), do: air <= -20
end
