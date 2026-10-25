defmodule Valimc.EntityActivityTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, ItemMotionState, Store}
  alias Valimc.Protocol.ItemStack

  defp cow(store, uuid, position) do
    {:ok, body} = Body.new("minecraft:cow")

    {:ok, store, {_, id, _}} =
      Store.create_record(store, {0, 0}, Store.body_record(body, uuid, position))

    body = store.entries[id].body
    body = put_in(body.mob.living.health.cooldown, 10)
    {Store.change_body(store, id, body), id}
  end

  defp item(store, uuid, x, age) do
    record = %{
      uuid: uuid,
      x: x,
      y: 64.0,
      z: 0.5,
      stack: ItemStack.new("stone"),
      motion: %ItemMotionState{age: age, pickup_delay: 12, portal_cooldown: 8}
    }

    {:ok, store, {_, id, _}} = Store.create_record(store, {0, 0}, record)
    {store, id}
  end

  test "counter work follows chunks while inactive entries and views stay untouched" do
    {store, active} = cow(Store.new(), <<1::128>>, {0.5, 64.0, 0.5})
    {store, frozen} = cow(store, <<2::128>>, {112.5, -200.0, 0.5})
    {store, expiring} = item(store, <<3::128>>, 2.5, 5999)
    {store, frozen_item} = item(store, <<4::128>>, 114.5, 5999)
    {next, expired} = Store.age_chunks(store, %{{0, 0} => 1}, -64, 101)
    assert next.entries[active].body.mob.living.health.cooldown == 9
    assert next.entries[active].lived == 1
    assert next.entries[frozen] == store.entries[frozen]
    assert next.views[frozen] == store.views[frozen]
    assert next.entries[frozen_item] == store.entries[frozen_item]
    assert next.views[frozen_item] == store.views[frozen_item]
    assert [{_, ^expiring, _}] = expired
    {same, []} = Store.age_chunks(next, %{{0, 0} => 1}, -64, 101)
    assert same == next
    {thawed, expired} = Store.age_chunks(next, %{{7, 0} => 1}, -64, 9000)
    assert thawed.entries[frozen].body.mob.living.health.cooldown == 9
    assert thawed.entries[frozen].lived == 1
    assert Enum.any?(expired, &(elem(&1, 1) == frozen))
    assert Enum.any?(expired, &(elem(&1, 1) == frozen_item))
  end

  test "an active orb can absorb a passive neighbour across a negative chunk border" do
    source = 9_000_000
    passive = source + 40

    records = [
      {source, -16.2, {-1, 0}},
      {passive, -15.8, {-1, 0}}
    ]

    store =
      Enum.reduce(records, Store.new(), fn {id, x, key}, store ->
        record = %{
          kind: :orb,
          uuid: <<id::128>>,
          entity_id: id,
          value: 3,
          count: 1,
          age: 100,
          x: x,
          y: 64.0,
          z: 0.5
        }

        {:ok, store, _} = Store.create_record(store, key, record)
        store
      end)

    # The active orb is not due to scan, so the inactive first-tick orb cannot
    # initiate a merge. Its own timers also remain frozen.
    store = put_in(store.entries[source].lived, 1)
    {quiet, []} = Store.age_chunks(store, %{{-2, 0} => 1}, -64, 1)
    assert quiet.entries[passive] == store.entries[passive]
    assert quiet.entries[source].count == 1
    scanning = put_in(quiet.entries[source].lived, 0)
    {merged, [{_, ^passive, _}]} = Store.age_chunks(scanning, %{{-2, 0} => 1}, -64, 2)
    assert merged.entries[source].count == 2
    assert merged.entries[passive] == store.entries[passive]
  end

  test "same-tick movement and adoption fences prevent a second living-counter turn" do
    {store, id} = cow(Store.new(), <<5::128>>, {0.5, 64.0, 0.5})
    store = Store.mark_simulated(store, [id], 10)
    {same, []} = Store.age_chunks(store, %{{0, 0} => 8}, -64, 10)
    assert same.entries[id].body.mob.living.health.cooldown == 10
    body = same.entries[id].body
    counters = Map.take(same.entries[id], [:aged_tick, :simulated_tick, :lived])
    adopted = Store.restore_live(store, id, body, counters)
    {same, []} = Store.age_chunks(adopted, %{{0, 0} => 1}, -64, 10)
    assert same.entries[id].body.mob.living.health.cooldown == 10
    {next, []} = Store.age_chunks(same, %{{0, 0} => 1}, -64, 11)
    assert next.entries[id].body.mob.living.health.cooldown == 9
  end
end

defmodule Valimc.RegionActivityTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, ItemMotionState, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{RegionData, Tickets}
  @moduletag :tmp_dir

  setup %{tmp_dir: base} do
    key = {180_000 + rem(System.unique_integer([:positive]), 3333) * 3, 92_000}
    Valimc.TestScope.isolate(key, world_path: base, item_simulation: true)
    state = RegionData.load(:overworld, key)
    %{state: state, key: key}
  end

  test "newly activated chunks inherit no other chunk's stalled planning budget", %{
    state: state,
    key: {rx, rz} = key
  } do
    chunks = [{rx * 8, rz * 8}, {rx * 8 + 7, rz * 8}]

    store =
      Enum.reduce(Enum.with_index(chunks), state.entities.store, fn {{cx, cz}, n}, store ->
        record = %{
          uuid: <<n + 20::128>>,
          x: cx * 16 + 0.5,
          y: 64.0,
          z: cz * 16 + 0.5,
          stack: ItemStack.new("stone"),
          motion: %ItemMotionState{pickup_delay: 100}
        }

        {:ok, store, _} = Store.create_record(store, key, record)
        store
      end)

    [old, new] = chunks
    tickets = Tickets.put(state.tickets, self(), :forced, [new], 0)

    state = %{
      state
      | tickets: tickets,
        game_tick: 100,
        entities: %{state.entities | store: store, age_debt: %{old => 5}}
    }

    next = RegionData.item_tick(state, System.monotonic_time(:millisecond))
    assert next.entities.age_debt == %{old => 5}
    old_id = store.uuids[<<20::128>>]
    new_id = store.uuids[<<21::128>>]
    assert next.entities.store.entries[old_id] == store.entries[old_id]
    assert next.entities.store.entries[new_id].motion.pickup_delay == 99
    RegionData.terminate(:shutdown, next)
  end

  test "a knot support check counts executed turns across inactive gaps", %{
    state: state,
    key: {rx, rz} = key
  } do
    {:ok, body} = Body.new("minecraft:leash_knot")
    chunk = {rx * 8 + 7, rz * 8}
    {cx, cz} = chunk
    record = Store.body_record(body, <<30::128>>, {cx * 16 + 0.5, 80.0, cz * 16 + 0.5})
    {:ok, store, {_, id, _}} = Store.create_record(state.entities.store, key, record)
    store = put_in(store.entries[id], Map.put(store.entries[id], :lived, 99))
    tickets = Tickets.put(state.tickets, self(), :forced, [{rx * 8, rz * 8}], 0)

    state = %{
      state
      | tickets: tickets,
        game_tick: 101,
        entities: %{state.entities | store: store}
    }

    frozen = RegionData.item_tick(state, System.monotonic_time(:millisecond))
    assert frozen.entities.store.entries[id].lived == 99
    tickets = Tickets.put(tickets, self(), :forced, [chunk], 0)

    thawed =
      RegionData.item_tick(
        %{frozen | tickets: tickets, game_tick: 1000},
        System.monotonic_time(:millisecond)
      )

    assert thawed.entities.store.entries[id].lived == 100

    removed =
      RegionData.item_tick(%{thawed | game_tick: 1001}, System.monotonic_time(:millisecond))

    refute Map.has_key?(removed.entities.store.entries, id)
    RegionData.terminate(:shutdown, removed)
  end
end
