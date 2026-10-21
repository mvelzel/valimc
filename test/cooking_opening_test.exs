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
