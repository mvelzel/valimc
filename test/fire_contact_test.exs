defmodule Valimc.Physics.BlockContactsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, CollisionContext, BlockContacts}

  defp frame(changes) do
    air = for x <- -3..5, y <- 62..68, z <- -1..1, into: %{}, do: {{x, y, z}, 0}
    %Frame{states: Map.merge(air, changes), fences: %{}, entities: %{}}
  end

  defp sample(f, from, to, flags \\ %{}) do
    facts =
      Map.merge(
        %{
          pose: :standing,
          feet: to,
          flying: false,
          spectator: false,
          weaving: false,
          grounded: false,
          careful: false,
          known_movement: {0.0, 0.0, 0.0},
          support_state: 0
        },
        flags
      )

    context =
      CollisionContext.entity(elem(to, 1)) |> CollisionContext.with_entity(0.0, false, false)

    BlockContacts.sample_paths(f, [%{from: from, to: to, axis: nil}], context, facts)
  end

  test "missing or invalid observations and path limits refuse without a partial plan" do
    point = {0.5, 64.0, 0.5}
    f = frame(%{{0, 64, 0} => 35_723})
    assert {:error, :unknown_block_state} = sample(f, point, point)
    assert {:error, :incomplete_fire_frame} = sample(%{f | states: %{}}, point, point)

    facts = %{
      pose: :standing,
      feet: point,
      flying: false,
      spectator: false,
      weaving: false,
      grounded: false,
      careful: false,
      known_movement: {0.0, 0.0, 0.0},
      support_state: 0
    }

    context = CollisionContext.entity(64.0) |> CollisionContext.with_entity(0.0, false, false)

    assert {:error, :invalid_fire_frame} =
             BlockContacts.sample_paths(
               frame(%{}),
               List.duplicate(%{from: point, to: point}, 102),
               context,
               facts
             )

    assert {:error, :invalid_fire_frame} =
             BlockContacts.sample_paths(frame(%{}), [], context, %{})
  end
end
