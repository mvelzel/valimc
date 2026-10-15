defmodule Valimc.Physics.ClimbContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, ClimbBlocks, ClimbContact}
  @pos {0, 64, 0}

  defp frame(state, below \\ 0),
    do: %Frame{states: %{@pos => state, {0, 63, 0} => below}, entities: %{}, fences: %{}}

  test "open trapdoors need a ladder below with matching direction" do
    assert {:ok, %{climbing: true}} =
             ClimbContact.sample(frame(8784, 7307), @pos, false, false, false)

    assert {:ok, %{climbing: false}} =
             ClimbContact.sample(frame(8784, 7309), @pos, false, false, false)

    assert {:ok, %{climbing: false}} =
             ClimbContact.sample(frame(8788, 7307), @pos, false, false, false)

    assert {:ok, %{climbing: false}} =
             ClimbContact.sample(frame(8784, 1), @pos, false, false, false)
  end

  test "gliding excludes vines but retains ladder/scaffolding facts; flight and spectator exclude all" do
    assert {:ok, %{climbing: true}} = ClimbContact.sample(frame(10092), @pos, false, false, false)
    assert {:ok, %{climbing: false}} = ClimbContact.sample(frame(10092), @pos, false, false, true)
    assert {:ok, %{climbing: true}} = ClimbContact.sample(frame(7307), @pos, false, false, true)

    assert {:ok, %{climbing: true, scaffolding: true}} =
             ClimbContact.sample(frame(24063), @pos, false, false, false)

    assert {:ok, %{climbing: false}} = ClimbContact.sample(frame(7307), @pos, true, false, false)
    assert {:ok, %{climbing: false}} = ClimbContact.sample(frame(7307), @pos, false, true, false)
  end

  test "missing contextual observations never become unclimbable air" do
    f = frame(8784)

    assert {:error, :incomplete_climb_frame} =
             ClimbContact.sample(
               %{f | states: Map.delete(f.states, {0, 63, 0})},
               @pos,
               false,
               false,
               false
             )

    assert {:error, :incomplete_climb_frame} =
             ClimbContact.sample(%{f | states: %{}}, @pos, false, false, false)

    assert {:error, :unknown_block_state} =
             ClimbContact.sample(frame(35_723), @pos, false, false, false)

    assert {:error, :invalid_climb_frame} = ClimbContact.sample(nil, @pos, false, false, false)
    assert {:error, :unknown_block_state} = ClimbBlocks.fetch(-1)
  end
end
