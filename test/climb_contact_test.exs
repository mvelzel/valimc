defmodule Valimc.Physics.ClimbContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, ClimbBlocks, ClimbContact}
  @pos {0, 64, 0}

  defp frame(state, below \\ 0),
    do: %Frame{states: %{@pos => state, {0, 63, 0} => below}, entities: %{}, fences: %{}}

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
