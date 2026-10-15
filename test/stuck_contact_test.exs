defmodule Valimc.Physics.StuckContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, CollisionContext, StuckContact}

  defp frame(changes) do
    air = for x <- -2..6, y <- 61..70, z <- -2..2, into: %{}, do: {{x, y, z}, 0}
    %Frame{states: Map.merge(air, changes), fences: %{}, entities: %{}}
  end

  defp context(y, fall \\ 5.0),
    do: CollisionContext.entity(y) |> CollisionContext.with_entity(fall, false, false)

  test "a crossed cobweb survives an endpoint outside its body" do
    from = {0.5, 64.0, 0.5}
    to = {3.5, 64.0, 0.5}

    {:ok, effect} =
      StuckContact.sample(frame(%{{1, 64, 0} => 2362}), from, to, context(64.0), %StuckContact{
        feet: to
      })

    assert effect.reset_fall and effect.last.kind == :cobweb
    assert effect.last.position == {1, 64, 0}
    assert effect.multiplier == {0.25, 0.05000000074505806, 0.25}
  end

  test "earlier fall reset changes a later powder snow contact geometry" do
    from = {0.5, 64.95, 0.5}
    to = {3.2, 64.95, 0.5}
    facts = %StuckContact{feet: to, pose: :swimming}
    f = frame(%{{3, 64, 0} => 30519})
    {:ok, missed} = StuckContact.sample(f, from, to, context(64.95), facts)
    refute missed.reset_fall
    assert missed.last == nil
    f = %{f | states: Map.put(f.states, {1, 64, 0}, 2362)}
    {:ok, ordered} = StuckContact.sample(f, from, to, context(64.95), facts)
    assert ordered.reset_fall and ordered.last.kind == :powder_snow
    assert ordered.multiplier == {0.8999999761581421, 1.5, 0.8999999761581421}
  end

  test "missing observations fail, while flight/spectator cannot create an effect" do
    from = {0.5, 64.0, 0.5}
    to = {3.5, 64.0, 0.5}
    f = frame(%{})
    f = %{f | states: Map.delete(f.states, {1, 64, 0})}

    assert {:error, :incomplete_stuck_frame} =
             StuckContact.sample(f, from, to, context(64.0), %StuckContact{feet: to})

    assert {:error, :invalid_stuck_context} =
             StuckContact.sample(f, from, to, CollisionContext.empty(), %StuckContact{feet: to})

    for facts <- [%StuckContact{flying: true}, %StuckContact{spectator: true}] do
      {:ok, effect} =
        StuckContact.sample(
          %Frame{states: %{}, fences: %{}, entities: %{}},
          from,
          to,
          context(64.0),
          facts
        )

      assert effect.multiplier == nil and effect.last == nil and not effect.reset_fall
    end
  end
end
