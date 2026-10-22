defmodule Valimc.World.ContainerClicks do
  @moduledoc """
  A click in a chest's or a furnace's menu (VMC-077i3): the container's owner
  applies it to the container and the player's inventory together, as a
  plain call from the player's group. The gestures are the menu click
  engine's (`Valimc.Menus.Click`) that move nothing into the world and no drag:
  pick up, shift-click and number swaps.

  Taking a furnace's earned output (its result while recipes are credited)
  awards the experience vanilla's `AbstractFurnaceBlockEntity` spawns as orbs
  at the player, and the player learns those recipes.
  """
  alias Valimc.Blocks.{Cooking, CookingAwards, CookingBlocks}
  alias Valimc.Menus.{Inventory, Menu, Click}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Containers
  alias Valimc.Entity.ExperienceOrbs

  @actions [:pickup, :quick_move, :swap]

  @doc """
  The menu's view of a container entry: a chest's rows and slots, or a
  furnace's kind and slots.
  """
  def view(%{rows: rows, slots: slots}), do: %{rows: rows, slots: slots}
  def view(%{kind: kind, cooking: cooking}), do: %{kind: kind, slots: cooking.slots}

  @doc """
  The click `action` on window `slot` with `button` against the container's
  `view`: `{:ok, slots, inventory}`.
  """
  def plan(%{slots: _} = view, %Inventory{drag: drag} = inventory, action, slot, button)
      when drag == nil and action in @actions do
    with {:ok, menu} <- menu(view),
         do: Click.plan_without_drops(menu, view.slots, inventory, action, slot, button)
  end

  def plan(_view, _inventory, _action, _slot, _button), do: {:error, :unsupported_container_click}

  defp menu(%{rows: rows}), do: {:ok, Menu.chest(rows)}

  defp menu(%{kind: kind}) do
    with {:ok, block} <- CookingBlocks.placement(kind, 0.0), do: {:ok, Menu.cooking(block)}
  end

  @doc """
  Apply a click to the entry at `position` of `containers`: `{:ok, containers,
  inventory, orbs, learned}`, where `orbs` are the experience orb records an
  earned output's withdrawal spawns at `at` and `learned` its recipes.
  """
  def apply(%Containers{} = containers, position, inventory, action, slot, button, at) do
    with {:ok, entry} <- Containers.observe(containers, position),
         {:ok, slots, inventory} <- plan(view(entry), inventory, action, slot, button) do
      cond do
        slots == view(entry).slots ->
          {:ok, containers, inventory, [], []}

        Map.has_key?(entry, :rows) ->
          with {:ok, next, _} <- Containers.replace(containers, position, entry.revision, slots),
               do: {:ok, next, inventory, [], []}

        entry.recipes != %{} and withdrawal?(elem(entry.cooking.slots, 2), elem(slots, 2)) ->
          award(containers, position, entry, slots, inventory, at)

        true ->
          with {:ok, block} <- CookingBlocks.placement(entry.kind, 0.0),
               {:ok, edited} <- Cooking.edit_slots(entry.cooking, slots, block),
               {:ok, next, _} <-
                 Containers.replace_cooking(
                   containers,
                   position,
                   entry.revision,
                   edited,
                   entry.recipes
                 ),
               do: {:ok, next, inventory, [], []}
      end
    else
      :error -> {:error, :missing_container}
      error -> error
    end
  end

  # Vanilla draws each recipe's fractional experience at random.
  defp award(containers, position, entry, slots, inventory, at) do
    recipes = Enum.sort(Map.keys(entry.recipes))

    draws =
      Map.new(recipes, fn name ->
        <<sample::24>> = :crypto.strong_rand_bytes(3)
        {name, sample}
      end)

    with {:ok, award} <- CookingAwards.plan(entry.recipes, draws),
         {:ok, block} <- CookingBlocks.placement(entry.kind, 0.0),
         {:ok, edited} <- Cooking.edit_slots(entry.cooking, slots, block),
         {:ok, next, _} <-
           Containers.replace_cooking(containers, position, entry.revision, edited, %{}) do
      {:ok, next, inventory, ExperienceOrbs.award(at, award), recipes}
    end
  end

  defp withdrawal?(nil, _), do: false
  defp withdrawal?(_, nil), do: true

  defp withdrawal?(before, after_stack),
    do: ItemStack.same_item?(before, after_stack) and after_stack.count < before.count
end
