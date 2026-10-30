defmodule Valimc.EntityPublicationTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.Publication

  defp view(id, kind, chunk), do: %{entity_id: id, kind: kind, chunk: chunk, uuid: <<id::128>>}
  defp stamp(table, chunk), do: :ets.lookup_element(table, {:entities, chunk}, 2)

  defp table do
    table = :ets.new(:entities, [:set, :public])
    epoch = make_ref()
    :ok = Publication.init(table, epoch)
    {table, epoch}
  end

  defp pass(rows, sources \\ [], frame \\ <<>>), do: %{rows: rows, sources: sources, frame: frame}

  test "every kind shares chunk rows; only named rows are rewritten and empty ones retire" do
    {table, epoch} = table()
    orb = view(3, :orb, {0, 0})
    one = view(1, :item, {0, 0})
    two = view(2, :item, {1, 0})

    :ok =
      Publication.publish(
        table,
        epoch,
        7,
        pass(
          %{{0, 0} => %{1 => one, 3 => orb}, {1, 0} => %{2 => two}},
          [{1, one}, {2, two}, {3, orb}]
        )
      )

    [{_, _, both}] = :ets.lookup(table, {:entities, {0, 0}})
    assert Map.keys(both) == [1, 3]
    unchanged = stamp(table, {1, 0})

    :ok = Publication.publish(table, epoch, 8, pass(%{{0, 0} => %{}}, [{3, nil}]))
    assert stamp(table, {1, 0}) == unchanged
    assert :ets.lookup(table, {:entities, {0, 0}}) == []
    assert Publication.source(table) |> Map.keys() == [1, 2]
    assert [{:entity_index, %{{1, 0} => _}, 3}] = :ets.lookup(table, :entity_index)
  end

  test "frames ring: newer frames after a tick, a gap past the ring, none for a new reader" do
    {table, epoch} = table()
    frame = fn tick -> <<1::32, 9::16, 1::32, tick>> end

    for tick <- 1..3,
        do: :ok = Publication.publish(table, epoch, tick, pass(%{}, [], frame.(tick)))

    assert Publication.frames(table, nil) == {:ok, 3, []}
    assert Publication.frames(table, 1) == {:ok, 3, [{2, frame.(2)}, {3, frame.(3)}]}
    # An empty frame is not written; its tick is skipped.
    :ok = Publication.publish(table, epoch, 4, pass(%{}))
    assert Publication.frames(table, 3) == {:ok, 3, []}
    :ok = Publication.publish(table, epoch, 100, pass(%{}, [], frame.(100)))
    assert Publication.frames(table, 3) == {:gap, 100}
  end
end
