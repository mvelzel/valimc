defmodule Valimc.Physics.FireContactTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockCollisions.Frame, CollisionContext, FireContact, InsideBlocks}
  @fire 4931
  @soul 5443

  defp frame(changes) do
    air = for x <- -3..5, y <- 62..68, z <- -1..1, into: %{}, do: {{x, y, z}, 0}
    %Frame{states: Map.merge(air, changes), fences: %{}, entities: %{}}
  end

  defp sample(f, from, to, flags \\ %{}) do
    facts =
      Map.merge(
        %{pose: :standing, feet: to, flying: false, spectator: false, weaving: false},
        flags
      )

    context =
      CollisionContext.entity(elem(to, 1)) |> CollisionContext.with_entity(0.0, false, false)

    FireContact.sample_paths(f, [%{from: from, to: to, axis: nil}], context, facts)
  end

  test "accepted paths retain crossed fire and later water even with a dry endpoint" do
    {:ok, result} =
      sample(frame(%{{1, 64, 0} => @fire, {2, 64, 0} => 89}), {0.5, 64.0, 0.5}, {3.5, 64.0, 0.5})

    assert result.active

    assert result.operations == [
             :clear_freeze,
             :fire_ignite,
             {:damage, :in_fire, 1.0},
             :extinguish
           ]

    assert {:ok, %{operations: [], active: false}} =
             sample(frame(%{{1, 64, 0} => @fire}), {3.5, 64.0, 0.5}, {3.5, 64.0, 0.5})
  end

  test "liquid block candidates alone cannot extinguish a body above their surface" do
    f = frame(%{{0, 64, 0} => 89})
    assert {:ok, %{operations: [:extinguish]}} = sample(f, {0.5, 64.8, 0.5}, {0.5, 64.8, 0.5})
    assert {:ok, %{operations: []}} = sample(f, {0.5, 64.9, 0.5}, {0.5, 64.9, 0.5})
    f = %{f | states: Map.put(f.states, {0, 65, 0}, 89)}
    assert {:ok, %{operations: [:extinguish]}} = sample(f, {0.5, 64.9, 0.5}, {0.5, 64.9, 0.5})
  end

  test "flight retains fire contacts, spectator skips them and each new tick has a fresh hit set" do
    f = frame(%{{0, 64, 0} => @soul})
    point = {0.5, 64.0, 0.5}

    for _ <- 1..2 do
      assert {:ok, %{operations: [:clear_freeze, :fire_ignite, {:damage, :in_fire, 2.0}]}} =
               sample(f, point, point, %{flying: true})
    end

    assert {:ok, %{operations: [], active: false}} =
             sample(%{f | states: %{}}, point, point, %{spectator: true})

    assert {:ok, {:fire, :full}} = InsideBlocks.fetch(@fire)
    assert {:ok, {:soul_fire, :full}} = InsideBlocks.fetch(@soul)
  end

  test "missing or invalid observations and path limits refuse without a partial plan" do
    point = {0.5, 64.0, 0.5}
    f = frame(%{{0, 64, 0} => 35_723})
    assert {:error, :unknown_block_state} = sample(f, point, point)
    assert {:error, :incomplete_fire_frame} = sample(%{f | states: %{}}, point, point)
    facts = %{pose: :standing, feet: point, flying: false, spectator: false, weaving: false}
    context = CollisionContext.entity(64.0) |> CollisionContext.with_entity(0.0, false, false)

    assert {:error, :invalid_fire_frame} =
             FireContact.sample_paths(
               frame(%{}),
               List.duplicate(%{from: point, to: point}, 102),
               context,
               facts
             )

    assert {:error, :invalid_fire_frame} = FireContact.sample_paths(frame(%{}), [], context, %{})
  end
end
