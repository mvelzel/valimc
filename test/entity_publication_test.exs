defmodule Valimc.EntityPublicationTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.Publication

  defp view(id, kind, chunk), do: %{entity_id: id, kind: kind, chunk: chunk, uuid: <<id::128>>}
  defp stamp(table, chunk), do: :ets.lookup_element(table, {:entities, chunk}, 2)

  test "every kind shares chunk rows; only changed chunks are rewritten and empty ones retire" do
    table = :ets.new(:entities, [:set, :public])
    epoch = make_ref()
    orb = view(3, :orb, {0, 0})

    :ok =
      Publication.publish(table, epoch, 7, %{
        1 => view(1, :item, {0, 0}),
        2 => view(2, :item, {1, 0}),
        3 => orb
      })

    [{_, _, both}] = :ets.lookup(table, {:entities, {0, 0}})
    assert Map.keys(both) == [1, 3] and both[3].tick == 7
    unchanged = stamp(table, {1, 0})

    # Moving item 1 to a new chunk rewrites {0, 0} and {2, 0}, not {1, 0}.
    :ok =
      Publication.publish(table, epoch, 7, %{
        1 => view(1, :item, {2, 0}),
        2 => view(2, :item, {1, 0}),
        3 => orb
      })

    assert stamp(table, {1, 0}) == unchanged
    assert [{_, _, %{3 => _}}] = :ets.lookup(table, {:entities, {0, 0}})

    :ok =
      Publication.publish(table, epoch, 7, %{
        1 => view(1, :item, {2, 0}),
        2 => view(2, :item, {1, 0})
      })

    assert :ets.lookup(table, {:entities, {0, 0}}) == []
    assert Publication.source(table, :items) |> Map.keys() == [1, 2]
  end

  test "frames ring: newer frames after a tick, a gap past the ring, none for a new reader" do
    table = :ets.new(:entities, [:set, :public])
    epoch = make_ref()
    for tick <- 1..3, do: :ok = Publication.publish(table, epoch, tick, %{}, %{1 => [tick]})
    assert Publication.frames(table, nil) == {:ok, 3, []}
    assert Publication.frames(table, 1) == {:ok, 3, [{2, %{1 => [2]}}, {3, %{1 => [3]}}]}
    # An empty frame is not written; its tick is skipped.
    :ok = Publication.publish(table, epoch, 4, %{})
    assert Publication.frames(table, 3) == {:ok, 3, []}
    :ok = Publication.publish(table, epoch, 100, %{}, %{1 => [100]})
    assert Publication.frames(table, 3) == {:gap, 100}
  end
end
