defmodule Valimc.TrackingPublicationCacheTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store, Tracking}

  defp create(type) do
    {:ok, body} = Body.new(type)

    {:ok, store, {_, id, _}} =
      Store.create_record(
        Store.new(),
        {0, 0},
        Store.body_record(body, <<1::128>>, {0.5, 64.0, 0.5})
      )

    tracking = Tracking.sync(%Tracking{}, store.views, nil)
    previous = %{source: store.views, views: Tracking.published(tracking, store.views)}
    {store, id, tracking, previous}
  end

  test "unchanged observations reuse rows while periodic tracking frames still advance" do
    {store, id, tracking, previous} = create("minecraft:cow")

    Enum.reduce(1..100, tracking, fn tick, tracking ->
      {tracking, frame} = Tracking.step(tracking, store.views, nil, tick)
      cached = Tracking.published(tracking, store.views, previous)
      assert cached == Tracking.published(tracking, store.views)
      if tick == 61, do: assert(frame[id] != nil)
      tracking
    end)
  end

  test "moves, metadata, collider changes, tracker replacement and removal match uncached rows" do
    {store, id, tracking, previous} = create("minecraft:shulker")
    body = store.entries[id].body
    open = put_in(body.data.peek_amount, 1.0)
    store = Store.change_body(store, id, open)
    {tracking, _} = Tracking.step(tracking, store.views, nil, 1)

    assert Tracking.published(tracking, store.views, previous) ==
             Tracking.published(tracking, store.views)

    refute Tracking.published(tracking, store.views, previous)[id].collider ==
             previous.views[id].collider

    {:ok, store, _} =
      Store.step_body(
        store,
        {0, 0},
        id,
        store.entries[id].revision,
        {20.5, 64.0, 0.5},
        Body.name(open, Valimc.Text.literal("shell"))
      )

    {tracking, _} = Tracking.step(tracking, store.views, nil, 2)

    assert Tracking.published(tracking, store.views, previous) ==
             Tracking.published(tracking, store.views)

    previous = %{source: store.views, views: Tracking.published(tracking, store.views)}
    reset = Tracking.sync(%Tracking{}, store.views, nil)

    assert Tracking.published(reset, store.views, previous) ==
             Tracking.published(reset, store.views)

    departure = %{records: [Map.put(Store.record(store.entries[id]), :entity_id, id)]}
    tracking = Tracking.sync(tracking, %{}, departure)
    assert Tracking.published(tracking, %{}, previous) == Tracking.published(tracking, %{})
    tracking = Tracking.sync(tracking, %{}, nil)
    assert Tracking.published(tracking, %{}, previous) == %{}
  end
end
