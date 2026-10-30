defmodule Valimc.EntityTrackerTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.EntityPackets
  alias Valimc.Protocol.ItemStack
  alias Valimc.Entity.{Store, Tracker, Tracking}

  defp entity(x, velocity \\ {0.0, 0.0, 0.0}, on_ground \\ false),
    do: %{
      entity_id: 7,
      uuid: <<7::128>>,
      x: x,
      y: 64.0,
      z: 0.5,
      velocity: velocity,
      on_ground: on_ground
    }

  defp packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  defp ticks(tracker, n, entity) do
    Enum.reduce(1..n, {tracker, []}, fn _, {tracker, sent} ->
      {tracker, packets} = Tracker.tick(tracker, entity)
      {tracker, sent ++ [packets]}
    end)
  end

  test "an item updates every 20 ticks with a relative move from the base the client has" do
    tracker = Tracker.new({0.5, 64.0, 0.5}, {0.0, 0.0, 0.0}, false)
    {tracker, sent} = ticks(tracker, 20, entity(0.75))
    # Tick 0 is an update tick; the next is tick 20.
    assert [[move] | rest] = sent
    assert move == packet(EntityPackets.move(7, {1024, 0, 0}, false))
    assert Enum.all?(rest, &(&1 == []))
    assert tracker.base == {0.75, 64.0, 0.5}
    {_tracker, [[move] | _]} = ticks(tracker, 1, entity(1.0))
    assert move == packet(EntityPackets.move(7, {1024, 0, 0}, false))
  end

  test "a sharp change of motion sends at once; a velocity change sends motion first" do
    tracker = %{Tracker.new({0.5, 64.0, 0.5}, {0.0, 0.0, 0.0}, false) | tick: 5}
    {_, []} = Tracker.tick(tracker, entity(0.5))

    {_, [motion, move]} =
      Tracker.tick(tracker, entity(0.6, {0.0, 0.3, 0.0}), true)

    assert motion == packet(EntityPackets.motion(7, {0.0, 0.3, 0.0}))
    assert move == packet(EntityPackets.move(7, {410, 0, 0}, false))
  end

  test "landing, a long run of moves and a far jump become absolute syncs" do
    tracker = Tracker.new({0.5, 64.0, 0.5}, {0.0, 0.0, 0.0}, false)
    landed = entity(0.5, {0.0, 0.0, 0.0}, true)
    assert {tracker, [sync]} = Tracker.tick(tracker, landed)
    assert sync == packet(EntityPackets.position(landed))
    assert tracker.on_ground and tracker.teleport_delay == 0

    far = entity(20.0, {0.0, 0.0, 0.0}, true)
    assert {_, [sync]} = Tracker.tick(%{tracker | tick: 20}, far)
    assert sync == packet(EntityPackets.position(far))

    {_, [sync]} = Tracker.tick(%{tracker | tick: 20, teleport_delay: 400}, landed)
    assert sync == packet(EntityPackets.position(landed))
  end

  test "a departing entity stays published, frozen, until its handoff clears; a returned one keeps its tracker" do
    {:ok, store, {epoch, id, revision}} =
      Store.create(Store.new(), {0, 0}, ItemStack.new("stone"), {0.5, 64.0, 0.5})

    pass = fn tracking, views, outgoing, tick ->
      Tracking.pass(tracking, views, {%{}, %{}}, outgoing, tick, simulated: MapSet.new([{0, 0}]))
    end

    {tracking, _} = pass.(%Tracking{}, store.views, nil, 1)
    {:ok, gone, [record]} = Store.withdraw(store, [{epoch, id, revision}])
    outgoing = %{destination: {1, 0}, records: [record], merge: nil}

    {leaving, publication} = pass.(tracking, gone.views, outgoing, 2)
    assert %{spawn: _, base: {0.5, 64.0, 0.5}} = Tracking.published(leaving, id)
    assert publication.frame == <<>> and publication.rows == %{}

    # Back before the clear (a rejected merge): the same tracker goes on.
    {back, _} = pass.(leaving, store.views, outgoing, 3)
    assert back.trackers[id].incarnation == leaving.trackers[id].incarnation
    assert back.departing == %{}

    {cleared, publication} = pass.(leaving, gone.views, nil, 3)
    assert Tracking.published(cleared) == %{} and cleared.trackers == %{}
    assert publication.rows == %{{0, 0} => %{}}
  end
end
