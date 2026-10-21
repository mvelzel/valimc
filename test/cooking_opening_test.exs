defmodule Valimc.CookingOpeningTest do
  use ExUnit.Case, async: true
  # They check the 250 ms window's edge (VMC-073).
  setup do: Valimc.TestScope.isolate(self(), owner_call_scale: 1)
  alias Valimc.CookingOpening
  alias Valimc.Physics.CookingBlocks
  alias Valimc.World.Containers
  @position {0, 64, 0}
  @grant %{
    kind: :open,
    mode: :survival,
    eye: {0.5, 65.5, 0.5},
    expires: 1100,
    hand: :main,
    secondary: false,
    main: false,
    off: true
  }

  test "native families open owned entries with no above-block dependency and preserve revision checks" do
    for kind <- [:furnace, :smoker, :blast_furnace] do
      {:ok, block} = CookingBlocks.placement(kind, 0.0)
      {:ok, _, entry} = Containers.create_cooking(%Containers{}, {0, 0}, @position, kind)

      assert {:cooking, ^block, ^entry} =
               CookingOpening.authorize(block, entry, @position, @grant, 1000)

      check = Map.merge(@grant, %{kind: :check, menu: :cooking, revision: entry.revision})
      assert :valid = CookingOpening.authorize(block, entry, @position, check, 1000)

      assert {:cooking, ^block, ^entry} =
               CookingOpening.authorize(block, entry, @position, %{check | revision: 0}, 1000)

      assert :pass =
               CookingOpening.authorize(
                 block,
                 entry,
                 @position,
                 %{@grant | secondary: true},
                 1000
               )

      assert {:error, :missing_cooking_entry} =
               CookingOpening.authorize(block, nil, @position, @grant, 1000)

      assert {:error, :invalid_cooking_context} =
               CookingOpening.authorize(block, entry, @position, %{check | menu: :table}, 1000)
    end
  end

  test "view range is native extended range while an initial interaction needs normal reach" do
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, _, entry} = Containers.create_cooking(%Containers{}, {0, 0}, @position, :furnace)
    grant = %{@grant | eye: {8.0, 65.5, 0.5}}
    assert CookingOpening.valid_view?(block, :survival, grant.eye, @position)

    assert {:error, :invalid_cooking_context} =
             CookingOpening.authorize(block, entry, @position, grant, 1000)

    check = Map.merge(grant, %{kind: :check, menu: :cooking, revision: entry.revision})
    assert :valid = CookingOpening.authorize(block, entry, @position, check, 1000)
    refute CookingOpening.valid_view?(block, :survival, {10.0, 65.5, 0.5}, @position)
  end

  test "expired grants and inconsistent owned kinds do not open or authorize item exchanges" do
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, _, other} = Containers.create_cooking(%Containers{}, {0, 0}, @position, :smoker)

    assert {:error, :missing_cooking_entry} =
             CookingOpening.authorize(block, other, @position, @grant, 1000)

    for expires <- [1000, 1251] do
      assert {:error, :expired_cooking_grant} =
               CookingOpening.authorize(
                 block,
                 other,
                 @position,
                 %{@grant | expires: expires},
                 1000
               )
    end

    actor = %{mode: :survival, eye: @grant.eye, health: 20.0, expires: 1100}
    assert :ok = CookingOpening.authorize_action(block, @position, actor, 1000)

    for invalid <- [%{actor | mode: :spectator}, %{actor | health: 0.0}, %{actor | expires: 1000}] do
      assert {:error, _} = CookingOpening.authorize_action(block, @position, invalid, 1000)
    end
  end
end
