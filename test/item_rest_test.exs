defmodule Valimc.ItemRestTest do
  # Resting items (VMC-081l): their counters on a chunk clock against every
  # tick's ageing.
  use ExUnit.Case, async: true
  alias Valimc.Entity.{ItemMotionState, Spatial, Store}
  alias Valimc.Protocol.ItemStack

  defp item(store, n, x, motion) do
    record = %{
      uuid: <<n::128>>,
      x: x,
      y: 64.0,
      z: 0.5,
      stack: ItemStack.new("stone"),
      motion: motion
    }

    {:ok, store, {_, id, _}} = Store.create_record(store, {0, 0}, record)
    {store, id}
  end

  defp ids(expired), do: expired |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  defp drop(store, expired) do
    Enum.reduce(expired, store, fn {epoch, id, revision}, acc ->
      {:ok, next} = Store.remove(acc, epoch, id, revision)
      next
    end)
  end

  # Each game tick's owed ticks per chunk: ticks out of simulation (none
  # owed), a planning pause's debt coming due at once, and a repeated game
  # tick (a sibling's second call) that ages nothing.
  defp schedule do
    for t <- 1..160 do
      cond do
        t in 30..33 -> {t, %{}}
        t == 34 -> {t, %{{0, 0} => 5}}
        t == 71 -> {70, %{{0, 0} => 1}}
        true -> {t, %{{0, 0} => 1}}
      end
    end
  end

  test "a resting item's record, view and expiry are every tick's ageing's" do
    motion = %ItemMotionState{age: 5880, on_ground: true}
    {store, a} = item(Store.new(), 1, 2.5, motion)
    {store, b} = item(store, 2, 4.5, %{motion | age: -32_768})
    {store, c} = item(store, 3, 6.5, %{motion | pickup_delay: 32_767, age: 5900})
    {store, d} = item(store, 4, 8.5, %{motion | age: 5000})
    # Every-tick ageing first gives each item its counters' entry.
    {store, []} = Store.age_chunks(store, %{{0, 0} => 1}, -64, 0)
    lazy = Enum.reduce([a, b, c, d], store, &Store.rest(&2, &1, [{{0, 0}, :seen}]))
    assert Spatial.awake(lazy.spatial, [{0, 0}]) == []

    {eager, lazy} =
      Enum.reduce(schedule(), {store, lazy}, fn {t, ticks}, {eager, lazy} ->
        {eager, gone} = Store.age_chunks(eager, ticks, -64, t)
        {next, resting} = Store.age_chunks(lazy, ticks, -64, t)
        assert ids(gone) == ids(resting), "tick #{t}"

        # Nothing of a resting item is rebuilt while it rests.
        for id <- Map.keys(next.spatial.resting),
            do:
              assert(next.entries[id] === lazy.entries[id] and next.views[id] === lazy.views[id])

        {eager, lazy} = {drop(eager, gone), drop(next, resting)}
        # One wakes partway and ages every tick again.
        lazy = if t == 100, do: Store.wake(lazy, d), else: lazy
        assert Store.records(eager) == Store.records(lazy), "tick #{t}"
        {eager, lazy}
      end)

    assert Map.keys(eager.entries) |> Enum.sort() == [b, d]
    assert Spatial.resting?(lazy.spatial, b) and not Spatial.resting?(lazy.spatial, d)
    assert Store.settled(lazy, lazy.entries[d]).motion.age == eager.entries[d].motion.age
  end

  test "a change through the store wakes a resting item with its settled counters" do
    {store, id} = item(Store.new(), 1, 2.5, %ItemMotionState{age: 10, on_ground: true})
    {store, []} = Store.age_chunks(store, %{{0, 0} => 1}, -64, 1)
    store = Store.rest(store, id, [{{0, 0}, :seen}])
    {store, []} = Store.age_chunks(store, %{{0, 0} => 7}, -64, 2)
    revision = store.entries[id].revision
    # A step made from the entry as it rested (a piston's push) keeps the
    # settled age.
    step = %{
      id: id,
      revision: revision,
      position: {2.6, 64.0, 0.5},
      motion: store.entries[id].motion
    }

    {:ok, pushed, _} = Store.advance(store, {0, 0}, store.epoch, [step])
    assert pushed.entries[id].motion.age == 18 and not is_map_key(pushed.entries[id], :rest)
    assert Spatial.awake(pushed.spatial, [{0, 0}]) == [id]
    assert pushed.spatial.resting == %{} and pushed.spatial.due == %{}

    # A replaced stack wakes it alike; a removal leaves nothing behind.
    {:ok, replaced, _} = Store.replace(store, store.epoch, id, revision, ItemStack.new("dirt"))
    assert replaced.entries[id].motion.age == 18 and replaced.spatial.deps == %{}
    {:ok, removed} = Store.remove(store, store.epoch, id, revision)
    assert removed.spatial.resting == %{} and removed.spatial.deps == %{}
  end

  test "resting items wake when a chunk they read is published anew or the border changes" do
    motion = %ItemMotionState{on_ground: true}
    {store, a} = item(Store.new(), 1, 2.5, motion)
    {store, b} = item(store, 2, 14.5, motion)
    {store, []} = Store.age_chunks(store, %{{0, 0} => 1}, -64, 1)
    same = Store.wake_stale(store, :border, fn _ -> :p end)
    store = Store.rest(same, a, [{{0, 0}, :p}])
    store = Store.rest(store, b, [{{0, 0}, :p}, {{1, 0}, :q}])

    unchanged =
      Store.wake_stale(store, :border, fn
        {0, 0} -> :p
        {1, 0} -> :q
      end)

    assert map_size(unchanged.spatial.resting) == 2

    published =
      Store.wake_stale(store, :border, fn
        {0, 0} -> :p
        {1, 0} -> :r
      end)

    assert Map.keys(published.spatial.resting) == [a]
    assert Spatial.awake(published.spatial, [{0, 0}]) == [b]

    bordered =
      Store.wake_stale(store, :moved, fn
        {0, 0} -> :p
        {1, 0} -> :q
      end)

    assert bordered.spatial.resting == %{}
    assert Enum.sort(Spatial.awake(bordered.spatial, [{0, 0}])) == [a, b]
  end
end
