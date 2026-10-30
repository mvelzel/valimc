defmodule Valimc.TrackingPublicationCacheTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, NativeMobs, Store, Tracking}

  defp create(type, store \\ Store.new()) do
    {:ok, body} = Body.new(type)

    {:ok, store, {_, id, _}} =
      Store.create_record(
        store,
        {0, 0},
        Store.body_record(body, <<1::128>>, {0.5, 64.0, 0.5})
      )

    {tracking, publication} = pass(%Tracking{}, store.views, 0, nil)
    assert %{{0, 0} => %{^id => _}} = publication.rows
    {store, id, tracking}
  end

  defp pass(tracking, views, tick, simulated, outgoing \\ nil),
    do: Tracking.pass(tracking, views, {%{}, %{}}, outgoing, tick, simulated: simulated)

  defp frame(publication),
    do: publication.frame |> Tracking.decode() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  test "a static section publishes nothing; its trackers tick only in simulated chunks" do
    {store, id, tracking} = create("minecraft:cow")
    here = MapSet.new([{0, 0}])

    # The new tracker ticks once (its view is new), then every tick in a
    # simulated chunk: an unchanged position goes out every 60 ticks.
    sent =
      Enum.reduce(1..121, {tracking, []}, fn tick, {tracking, sent} ->
        {tracking, publication} = pass(tracking, store.views, tick, here)
        assert publication.rows == %{} and publication.sources == []
        {tracking, if(publication.frame == <<>>, do: sent, else: [tick | sent])}
      end)
      |> elem(1)
      |> Enum.reverse()

    assert sent == [1, 61, 121]
    assert frame(elem(pass(tracking, store.views, 1, here), 1))[id] != nil

    # Outside simulated chunks only a changed view ticks its tracker.
    {quiet, _} = pass(tracking, store.views, 1, MapSet.new())

    Enum.reduce(2..130, quiet, fn tick, tracking ->
      {tracking, publication} = pass(tracking, store.views, tick, MapSet.new())
      assert publication == %{rows: %{}, sources: [], frame: <<>>}
      tracking
    end)
  end

  test "moves, data, colliders, a new tracker and removal rewrite the rows they touch" do
    # A native shulker, as an owner's is; its section changes it.
    {store, id, tracking} =
      create("minecraft:shulker", %{Store.new() | native: NativeMobs.new({0, 0})})

    ref = store.native.ref
    before = Tracking.published(tracking, id)

    change = fn store, {:ok, {_, events, {position, row}}}, at ->
      Store.native_change(store, id, at || position, row, events)
    end

    store = change.(store, Valimc.Native.mob_section_data(ref, id, :peek_amount, 1.0), nil)
    {tracking, publication} = pass(tracking, store.views, 1, MapSet.new())
    assert [{^id, _}] = publication.sources
    assert %{{0, 0} => %{^id => row}} = publication.rows
    refute row.collider == before.collider
    assert row.tick == 1

    named = Valimc.Native.mob_section_name(ref, id, Valimc.Text.literal("shell"))
    store = change.(store, named, {20.5, 64.0, 0.5})

    {tracking, publication} = pass(tracking, store.views, 2, MapSet.new())
    assert publication.rows[{0, 0}] == %{}
    assert %{^id => %{at: {20.5, 64.0, 0.5}}} = publication.rows[{1, 0}]

    reset = elem(pass(%Tracking{}, store.views, 2, nil), 0)
    refute Tracking.published(reset, id).tracker == Tracking.published(tracking, id).tracker

    departure = %{records: [Map.put(Store.record(store.entries[id]), :entity_id, id)]}
    {leaving, publication} = pass(tracking, %{}, 3, MapSet.new(), departure)
    assert publication.rows == %{} and publication.sources == [{id, nil}]
    assert Tracking.published(leaving, id).at == {20.5, 64.0, 0.5}
    {cleared, publication} = pass(leaving, %{}, 4, MapSet.new())
    assert publication.rows == %{{1, 0} => %{}}
    assert Tracking.published(cleared) == %{} and cleared.trackers == %{}
  end
end
