defmodule Valimc.TxnPermitsTest do
  use ExUnit.Case, async: true
  # Contact permits live the play lifetime here (VMC-073).
  setup do: Valimc.TestScope.isolate(self(), owner_call_scale: 1)
  alias Valimc.Txn.Permits

  # {kind, limit, one permit per source?}
  @kinds [
    {:pickup, 128, true},
    {:container, 128, true},
    {:item_merge, 8, true},
    {:mining, 128, false},
    {:placement, 128, false}
  ]

  defp issue(permits, kind, source, now, position \\ {0, 64, 0}),
    do: Permits.issue(permits, kind, nil, source, [position], %{kind: kind}, now)

  test "every kind bounds live grants; expiry and release reclaim them" do
    for {kind, limit, per_source} <- @kinds do
      full =
        Enum.reduce(1..limit, Permits.new(), fn n, permits ->
          {:ok, next, _} = issue(permits, kind, <<n::128>>, 0)
          next
        end)

      assert {:error, _full} = issue(full, kind, <<0::128>>, 1)
      {token, _} = Enum.find(full.entries, fn {_, e} -> e.source == <<1::128>> end)
      assert Permits.release(full, token, <<2::128>>) == full
      assert {:ok, _, _} = issue(Permits.release(full, token, <<1::128>>), kind, <<0::128>>, 1)
      assert {:ok, renewed, _} = issue(full, kind, <<0::128>>, Permits.lifetime(kind))
      assert map_size(renewed.entries) == 1

      {:ok, one, _} = issue(Permits.new(), kind, <<1::128>>, 0)

      if per_source,
        do: assert({:error, _pending} = issue(one, kind, <<1::128>>, 1)),
        else: assert({:ok, _, _} = issue(one, kind, <<1::128>>, 1))
    end
  end
end
