defmodule Valimc.EntityPublicationTest do
  use ExUnit.Case, async: true
  alias Valimc.World.EntityPublication

  defp view(id, kind, chunk), do: %{entity_id: id, kind: kind, chunk: chunk, uuid: <<id::128>>}
  defp stamp(table, chunk), do: :ets.lookup_element(table, {:entities, chunk}, 2)

  test "both kinds share chunk rows; only changed chunks are rewritten and empty ones retire" do
    table = :ets.new(:entities, [:set, :public])
    epoch = make_ref()

    :ok =
      EntityPublication.publish(table, epoch, :items, %{
        1 => view(1, :item, {0, 0}),
        2 => view(2, :item, {1, 0})
      })

    :ok = EntityPublication.publish(table, epoch, :orbs, %{3 => view(3, :orb, {0, 0})})
    [{_, _, both}] = :ets.lookup(table, {:entities, {0, 0}})
    assert Map.keys(both) == [1, 3]
    unchanged = stamp(table, {1, 0})

    # Moving item 1 to a new chunk rewrites {0, 0} and {2, 0}, not {1, 0}.
    :ok =
      EntityPublication.publish(table, epoch, :items, %{
        1 => view(1, :item, {2, 0}),
        2 => view(2, :item, {1, 0})
      })

    assert stamp(table, {1, 0}) == unchanged
    assert [{_, _, %{3 => _}}] = :ets.lookup(table, {:entities, {0, 0}})

    :ok = EntityPublication.publish(table, epoch, :orbs, %{})
    assert :ets.lookup(table, {:entities, {0, 0}}) == []
    assert EntityPublication.source(table, :items) |> Map.keys() == [1, 2]
  end
end
